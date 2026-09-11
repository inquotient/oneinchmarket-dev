#!/usr/bin/env bash
# OpenSearch 의 보안 설정(internal_users 등)을 살아 있는 클러스터에 밀어 넣는다.
#
# ★★ 왜 필요한가 — **Secret 을 바꾸고 파드를 재기동해도 반영되지 않는다.**
#   StatefulSet 의 initContainer 가 `internal_users.yml` 을 다시 굽기는 하지만,
#   `plugins.security.allow_default_init_securityindex` 는 보안 인덱스가
#   **비어 있을 때만** 초기화한다. 이미 초기화된 클러스터에서는 파일이 바뀌어도
#   살아 있는 설정은 그대로다.
#   실측(2026-09-11): `ingest` 비밀번호를 회전했더니 Data Prepper 의 수집이
#   401 로 끊겼고, 파드를 다시 만들어도 낫지 않았다. 이 스크립트를 돌리자
#   그 자리에서 복구됐다 — LOCAL-DEPLOYMENT §9-17.
#
# ★ 증상이 조용하다: 파드는 1/1 Running 이고 OpenSearch 도 green 이며
#   오류는 수집기 쪽에만 나온다. 그래서 "Secret 만 바꾸면 된다" 는 다른 DB 의
#   경험이 여기서는 함정이 된다.
#
# 언제 돌리나
#   · opensearch-secret 의 비밀번호를 바꾼 뒤
#   · internal_users 를 렌더하는 initContainer 스크립트를 고친 뒤
#   · "자격은 맞는 것 같은데 401" 일 때
#
# ★ 자동 실행을 두지 않았다 — 로테이션 CronJob 을 만들지 않기로 한 이유가
#   §9-17 에 있다(OIDC 로 옮기면 대부분 불필요해진다). 그 결정이 바뀌면
#   이 스크립트를 그 Job 안에서 부르면 된다.
set -Eeuo pipefail
trap 'echo "[os-sec][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

NS="${NS:-local}"
POD="${POD:-opensearch-0}"
CONTAINER="${CONTAINER:-opensearch}"
HOME_DIR=/usr/share/opensearch
log() { echo "[os-sec] $*"; }

log "대상 ${NS}/${POD}"

# ★ 파드가 Ready 인지 먼저 본다. 기동 중에 밀어 넣으면 securityadmin 이
#   클러스터를 못 찾고 실패하는데, 그 오류가 자격 문제처럼 읽힌다.
ready=$(kubectl -n "$NS" get pod "$POD" \
  -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "")
if [ "$ready" != "true" ]; then
  echo "[os-sec] ${POD} 이 Ready 가 아니다(ready=${ready:-없음}) — 기동을 기다릴 것" >&2
  exit 1
fi

# 구운 결과가 실제로 있는지 확인한다. 없으면 initContainer 가 실패한 것이고,
# 그 상태로 securityadmin 을 돌리면 **빈 설정을 밀어 넣어** 더 나빠진다.
log "렌더된 보안 설정 확인"
kubectl -n "$NS" exec "$POD" -c "$CONTAINER" -- \
  sh -c "test -s ${HOME_DIR}/config/opensearch-security/internal_users.yml" \
  || { echo "[os-sec] internal_users.yml 이 비었다 — initContainer 로그를 볼 것" >&2; exit 1; }

users=$(kubectl -n "$NS" exec "$POD" -c "$CONTAINER" -- \
  sh -c "grep -cE '^[a-z]+:' ${HOME_DIR}/config/opensearch-security/internal_users.yml" 2>/dev/null || echo 0)
log "  사용자 항목 ${users}개"

log "securityadmin.sh 실행"
# ★ admin 인증서로 인증한다 — 비밀번호가 아니다. 그래서 이 스크립트는
#   비밀번호를 전혀 만지지 않는다(로그에 샐 여지가 없다).
kubectl -n "$NS" exec "$POD" -c "$CONTAINER" -- bash -c "
  cd ${HOME_DIR}/plugins/opensearch-security/tools &&
  ./securityadmin.sh \
    -cd ${HOME_DIR}/config/opensearch-security \
    -icl -nhnv \
    -cacert ${HOME_DIR}/config/certs/ca.crt \
    -cert   ${HOME_DIR}/config/admin-certs/tls.crt \
    -key    ${HOME_DIR}/config/admin-certs/tls.key \
    -h localhost -p 9200" 2>&1 | tail -20

# ★★ 판정은 "Done with success" 문구가 아니라 **실제 로그인**으로 한다.
#   이 레포가 반복해서 밟은 부류다 — 성공 출력이 성공을 뜻하지 않는다(Gotcha 12).
log "실제 로그인으로 판정"
tmp=$(mktemp -d); trap 'shred -u "$tmp"/* 2>/dev/null; rm -rf "$tmp"' EXIT
kubectl -n "$NS" get secret opensearch-secret -o jsonpath='{.data.ingest-password}' \
  | base64 -d > "$tmp/ingest"
code=$(kubectl -n "$NS" exec "$POD" -c "$CONTAINER" -- \
  env P="$(cat "$tmp/ingest")" sh -c \
  'curl -sk -o /dev/null -w "%{http_code}" -u "ingest:$P" https://localhost:9200/_cluster/health' 2>/dev/null || echo 000)

if [ "$code" = "200" ]; then
  log "ingest 계정 로그인 200 — 반영됐다"
else
  echo "[os-sec] ingest 로그인이 ${code} 다 — 반영되지 않았다" >&2
  exit 1
fi

log "완료. 수집기를 재기동해 새 자격을 읽게 할 것:"
log "  kubectl -n ${NS} rollout restart deploy/data-prepper"
