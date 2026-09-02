#!/usr/bin/env bash
# P0 블로커 #1 해소 (로컬 한정) — Secret 이 0개 렌더되어 secretKeyRef 참조
# 워크로드가 CreateContainerConfigError 로 기동하지 못하던 문제.
#
# 왜 SOPS 가 아닌가:
#   *.enc.yaml 12개가 전부 PLACEHOLDER 라 보존할 실제 비밀값이 없다.
#   그리고 ArgoCD CMP 플러그인 이름 불일치(G3)로 SOPS 경로 자체가 미작동이다.
#   로컬은 런타임 생성으로 풀고, dev/prod 의 SOPS 정비는 G2·G3 로 남긴다.
#
# 멱등하다 — 이미 있는 Secret 은 건드리지 않는다.
# 재실행이 비밀번호를 갈아치우면 기동 중인 워크로드가 깨진다.
set -Eeuo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NS="${NS:-local}"

# 파이프를 쓰지 않는다 — head 가 먼저 끝나면 tr 이 SIGPIPE 로 죽고
# pipefail 이 이를 잡아 스크립트 전체가 중단된다.
gen() { openssl rand -hex "$(( ${1:-24} / 2 ))"; }

mk() {  # mk <secret-name> <key=value> ...
  local name="$1"; shift
  if kubectl -n "$NS" get secret "$name" >/dev/null 2>&1; then
    echo "  skip   $name (이미 존재)"
    return
  fi
  local args=()
  for kv in "$@"; do args+=(--from-literal="$kv"); done
  kubectl -n "$NS" create secret generic "$name" "${args[@]}" >/dev/null
  kubectl -n "$NS" label secret "$name" \
    app.kubernetes.io/part-of=oneinchmarket \
    app.kubernetes.io/managed-by=local-script >/dev/null
  echo "  create $name  (keys: $(printf '%s ' "$@" | sed 's/=[^ ]*//g'))"
}

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"
echo "[secrets] 네임스페이스: $NS"

# ── 워크로드가 참조하는 키 이름과 로테이션 CronJob 이 참조하는 키 이름이
#    서로 다른 건이 4건 있다 (문서가 지적한 불일치).
#    로컬에서는 양쪽 키를 같은 값으로 함께 넣어 둘 다 동작하게 한다.
PG=$(gen);   MARIA_ROOT=$(gen); MARIA_APP=$(gen); MONGO=$(gen); REDIS=$(gen)
MINIO_PW=$(gen 32); KC_ADMIN=$(gen); GL_ROOT=$(gen)

mk postgresql-secret  "postgresql-password=$PG"      "postgres-password=$PG"
mk mariadb-secret     "root-password=$MARIA_ROOT"    "mariadb-root-password=$MARIA_ROOT" "app-password=$MARIA_APP"
mk mongodb-secret     "root-password=$MONGO"         "mongodb-root-password=$MONGO"
mk redis-secret       "redis-password=$REDIS"
mk minio-secret       "root-user=oimadmin"           "root-password=$MINIO_PW" \
                      "minio-access-key=oimadmin"    "minio-secret-key=$MINIO_PW"

# ── PostgreSQL 을 공유하는 소비자들. 각자 다른 비밀번호를 갖는다.
#    postgres-bootstrap Job 이 이 Secret 들을 읽어 같은 값으로 롤을 만든다.
mk keycloak-secret       "admin-password=$KC_ADMIN"  "db-password=$(gen)"
mk gitlab-secret         "db-password=$(gen)"        "root-password=$GL_ROOT" "admin-token=$(gen 32)"
mk gitlab-deploy-token   "token=$(gen 32)"
mk apicurio-secret       "db-password=$(gen)"
mk hive-metastore-secret "db-password=$(gen)"
mk cmmn-api-secret       "db-password=$MARIA_APP"     # MariaDB cmmn DB 사용자와 동일해야 한다
mk elasticsearch-secret  "elastic-password=$(gen)"    # ECK 가 만드는 -es-elastic-user 와 별개다
mk grafana-secret        "admin-password=$(gen)"
# GlitchTip — SECRET_KEY 는 Django 세션·서명 키다. 50자 이상 권장.
mk glitchtip-secret      "db-password=$(gen)"        "secret-key=$(gen 64)"
mk argocd-admin-secret   "admin-password=$(gen)"
# Slack 미연동. 빈 값이면 Falcosidekick 이 Slack 출력을 비활성한다.
mk falcosidekick-secret  "slack-webhook-url="

# ── 3단계 거버넌스 ────────────────────────────────────────────────
#    Ranger admin 은 웹 로그인 비밀번호도 RANGER_DB_PASSWORD 로 설정한다
#    (이미지의 ranger.sh 가 rangerAdmin_password 에 같은 값을 쓴다).
#
#    ★ Ranger 의 비밀번호 정책을 통과해야 한다 — 대문자·소문자·숫자·
#      특수문자(@#$%^&+=)를 각각 하나 이상, 8자 이상. gen() 의 hex 는
#      소문자와 숫자뿐이라 정책에 걸리고, 걸리면 setup 이 조용히 넘어가
#      **admin 계정이 기본값 admin/admin 으로 남는다.** 실제로 그랬다.
#      DB 롤 비밀번호로도 쓰이지만 PostgreSQL 은 문자 구성을 따지지 않는다.
DS_DM=$(gen); LAM_PW=$(gen); KNOX_MS=$(gen 32)
RANGER_PW="Rg$(gen 16)#A1"

mk ds389-secret   "dm-password=$DS_DM"          # cn=Directory Manager
mk lam-secret     "master-password=$LAM_PW"     # LAM 마스터 설정 비밀번호
mk ranger-secret  "db-password=$RANGER_PW"      # ranger 롤 + admin 웹 로그인
mk knox-secret    "master-secret=$KNOX_MS"      # Knox 키스토어 마스터 시크릿

# ── 4단계 security-min ────────────────────────────────────────────
# Wazuh API 도 비밀번호 정책이 있다(대소문자·숫자·특수).
# indexer 의 OpenSearch security 사용자 2명도 같은 형식으로 만든다 —
# internal_users.yml 의 bcrypt 해시는 파드 기동 시 initContainer 가
# 이 값들로 생성한다(해시를 커밋하지 않는 이유다).
WZ_PW="Wz$(gen 16)#A1"; WZ_IDX="Ix$(gen 16)#A1"; WZ_FB="Fb$(gen 16)#A1"
mk wazuh-secret   "api-username=wazuh-wui" \
                  "api-password=$WZ_PW" \
                  "indexer-admin-password=$WZ_IDX" \
                  "indexer-filebeat-password=$WZ_FB"

echo
echo "[secrets] 접속 정보 (이 값들은 커밋되지 않는다)"
printf "  MinIO      oimadmin / %s\n" "$MINIO_PW"
printf "  Keycloak   admin / %s\n"    "$KC_ADMIN"
printf "  GitLab     root / %s\n"     "$GL_ROOT"
printf "  Ranger     admin / %s\n"   "$RANGER_PW"
printf "  LAM        (마스터 설정) %s\n" "$LAM_PW"
printf "  DS389      cn=Directory Manager / %s\n" "$DS_DM"
printf "  Wazuh API  wazuh-wui / %s\n"       "$WZ_PW"
printf "  Wazuh idx  admin / %s\n"           "$WZ_IDX"
echo
echo "[secrets] 생성 결과"
kubectl -n "$NS" get secret -l app.kubernetes.io/part-of=oneinchmarket
