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

gen() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-24}"; }

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
mk argocd-admin-secret   "admin-password=$(gen)"
# Slack 미연동. 빈 값이면 Falcosidekick 이 Slack 출력을 비활성한다.
mk falcosidekick-secret  "slack-webhook-url="

echo
echo "[secrets] 접속 정보 (이 값들은 커밋되지 않는다)"
printf "  MinIO      oimadmin / %s\n" "$MINIO_PW"
printf "  Keycloak   admin / %s\n"    "$KC_ADMIN"
printf "  GitLab     root / %s\n"     "$GL_ROOT"
echo
echo "[secrets] 생성 결과"
kubectl -n "$NS" get secret -l app.kubernetes.io/part-of=oneinchmarket
