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
# debezium-password 는 CDC 전용 계정이다(mariadb-bootstrap 이 만든다).
# 앱 계정과 같은 값을 쓰지 않는다 — 권한이 다르기 때문이다(§8-44).
mk mariadb-secret     "root-password=$MARIA_ROOT"    "mariadb-root-password=$MARIA_ROOT" "app-password=$MARIA_APP" "debezium-password=$(gen)"
mk mongodb-secret     "root-password=$MONGO"         "mongodb-root-password=$MONGO"
mk redis-secret       "redis-password=$REDIS"
# ShardingSphere-Proxy 의 프록시 사용자(proxyadmin). 뒤쪽 PostgreSQL 자격과
# **별개**여야 한다 — 프록시 자격이 새도 DB 자격은 지켜진다(§8-44 와 같은 이유).
# Backstage — db-password 는 PostgreSQL 롬, backend-secret 은 세션·토큰
# 서명 키다. 둘을 같은 값으로 쓰지 않는다 — 역할이 다르고
# 하나가 새면 둘 다 새는 구조를 만들지 않는다(§8-44).
# ★ oidc-client-secret 은 Keycloak 클라이언트 시크릿이다. **소비자 쪽에** 둔다 —
#   keycloak-realm 부트스트랩이 이 값을 읽어 클라이언트에 심는다. 반대로 두면
#   Backstage 가 남의 Secret 을 읽어야 한다.
mk backstage-secret "db-password=$(gen)" "backend-secret=$(gen 32)" "oidc-client-secret=$(gen 32)" "session-secret=$(gen 32)"
# Temporal — 이력·가시성 DB 를 같은 롤로 쓴다(postgres-bootstrap 이 둘을 만든다).
mk temporal-secret "db-password=$(gen)"
# Airflow — 넷이 필요하고 서로 역할이 다르다.
#   db-password     메타데이터 DB (postgres-bootstrap 이 같은 값을 쓴다)
#   fernet-key      연결·변수를 DB 에 암호화해 넣는 키
#   api-secret-key  세션 서명
#   jwt-secret      태스크 실행 API 의 토큰 서명
#   admin-password  UI 관리자(FAB) — db-migrate Job 이 이 값으로 맞춘다
# ★★ fernet-key 는 아무 난수가 아니다 — **32바이트를 urlsafe base64** 한
#   값이어야 한다. `gen` 의 hex 문자열을 주면 Airflow 가
#   `Fernet key must be 32 url-safe base64-encoded bytes` 로 기동하지 않는다.
# ★ 이 키를 바꾸면 그 전에 암호화된 연결·변수를 영원히 못 읽는다
#   (GitLab 의 db_key_base 와 같은 부류 — Gotcha 51·72).
fernet() { python3 -c "import base64,os,sys; sys.stdout.write(base64.urlsafe_b64encode(os.urandom(32)).decode())"; }
#   s3-secret-key   MinIO 전용 사용자(airflow)의 비밀키 — 태스크 로그 보존용.
#     ★ minio-bootstrap 이 이 값으로 MinIO 사용자를 만든다. 원천이 하나여야
#       회전 때 어긋나지 않는다(Gotcha 117).
mk airflow-secret "db-password=$(gen)" "fernet-key=$(fernet)" "api-secret-key=$(gen 32)" "jwt-secret=$(gen 32)" "admin-password=$(gen 24)" "s3-secret-key=$(gen 32)"
# OpenSearch — security 플러그인의 internal_users. StatefulSet 의 initContainer 가
# 이 값들을 bcrypt 해시로 바꿔 internal_users.yml 을 렌더한다(평문은 저장되지 않는다).
#   admin      — 사람이 쓰는 관리 계정 · Dashboards 로그인
#   ingest     — data-prepper 가 쓰는 수집 계정
#   dashboards — Dashboards 자신의 서비스 계정(예약 이름 kibanaserver 로 렌더된다)
mk opensearch-secret "admin-password=$(gen 24)" "ingest-password=$(gen 24)" "dashboards-password=$(gen 24)"
# Gravitee — MongoDB 전용 사용자(mongodb-bootstrap 이 만든다).
# ★★ Gravitee 는 **관리자 계정을 설정 파일에 둔다**(memory 공급자). 그 자리에
#   들어가는 것은 평문이 아니라 **bcrypt 해시**다. 그래서 키가 둘이다 —
#   사람이 로그인할 평문(admin-password)과 설정에 박히는 해시.
# ★★ prefix=2a 가 필수다 — Gravitee 의 memory IDP 는 `$2a$` 만 받는다.
#   python 기본값은 `$2b$` 이고, 그것을 넣으면 오류 없이 401 만 난다.
bcrypt() { python3 -c "import bcrypt,sys; sys.stdout.write(bcrypt.hashpw(sys.stdin.buffer.read().strip(), bcrypt.gensalt(rounds=10, prefix=b'2a')).decode())"; }
GRAVITEE_ADMIN_PW="$(gen 24)"
mk gravitee-secret "db-password=$(gen)" "jwt-secret=$(gen 32)" "admin-password=${GRAVITEE_ADMIN_PW}" "admin-password-bcrypt=$(printf %s "${GRAVITEE_ADMIN_PW}" | bcrypt)"
unset GRAVITEE_ADMIN_PW
mk shardingsphere-secret "proxy-password=$(gen)"
# ProxySQL (§8-76). admin 은 런타임 설정 인터페이스(6032), monitor 는 백엔드
# 헬스체크용 계정이다 — mariadb-bootstrap 이 'proxysql-monitor'@'%' 를
# USAGE 권한만으로 만든다. 앱 계정(cmmn)을 재사용하지 않는다(§8-44).
mk proxysql-secret "admin-password=$(gen)" "monitor-password=$(gen)"
mk minio-secret       "root-user=oimadmin"           "root-password=$MINIO_PW" \
                      "minio-access-key=oimadmin"    "minio-secret-key=$MINIO_PW"

# ── PostgreSQL 을 공유하는 소비자들. 각자 다른 비밀번호를 갖는다.
#    postgres-bootstrap Job 이 이 Secret 들을 읽어 같은 값으로 롤을 만든다.
# portal-user-password — 개발자 포털에 로그인할 realm 사용자(`portal`).
# 이 realm 에는 사용자가 없어서 클라이언트만 만들면 로그인할 대상이 없다.
mk keycloak-secret       "admin-password=$KC_ADMIN"  "db-password=$(gen)" "portal-user-password=$(gen)"
mk gitlab-secret         "db-password=$(gen)"        "root-password=$GL_ROOT" "admin-token=$(gen 32)"
mk gitlab-deploy-token   "token=$(gen 32)"
mk apicurio-secret       "db-password=$(gen)"
mk hive-metastore-secret "db-password=$(gen)"
mk cmmn-api-secret       "db-password=$MARIA_APP"     # MariaDB cmmn DB 사용자와 동일해야 한다
# elasticsearch-secret 은 없앴다(2026-09-11) — Elasticsearch 를 철거하고
# OpenSearch 로 옮겼다. 자격의 원천은 위의 opensearch-secret 하나다.
mk grafana-secret        "admin-password=$(gen)"
# GlitchTip — SECRET_KEY 는 Django 세션·서명 키다. 50자 이상 권장.
mk glitchtip-secret      "db-password=$(gen)"        "secret-key=$(gen 64)"
# Jenkins — JCasC 가 이 값으로 관리자 계정을 만든다(설치 마법사 대신).
JK_ADMIN="Jk$(gen 16)#A1"
mk jenkins-secret        "admin-password=$JK_ADMIN"
# ClickHouse — OpenReplay 전용(ADR-070).
mk clickhouse-secret     "password=$(gen)"
# OpenReplay — PostgreSQL 롤. ClickHouse·Redis·Kafka·MinIO 는 기존 것을 쓴다.
mk openreplay-secret     "db-password=$(gen)"
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


# ── 7단계 security-full ───────────────────────────────────────────
# Dependency-Track — 공용 PG 롤 비밀번호. 관리자 초기 비밀번호는 제품이
# admin/admin 으로 강제 생성하고 첫 로그인에서 변경을 요구한다.
#   ★★ kek 는 v5 가 새로 요구하는 것이다(v4 에는 없었다, §8-74). 저장소·분석기
#     자격증명을 DB 에 암호화해 넣고 그 키를 이 KEK 로 감싼다. 없으면 apiserver
#     가 아예 기동하지 않는다. **32바이트 난수의 base64** 여야 한다 —
#     gen() 은 hex 라 여기 쓸 수 없다.
#     ★ 이 값을 잃으면 저장된 자격증명을 복호화할 수 없다. DefectDojo 의
#       credential-aes-256-key 와 같은 성격이다.
mk dependency-track-secret "db-password=$(gen)" \
                           "kek=$(openssl rand -base64 32)"

# SafeLine WAF — 공용 PG 롤 비밀번호. 관리자 계정은 mgt 가 첫 기동에
# 생성하고 로그에 1회만 출력한다.
mk safeline-secret "db-password=$(gen)"
# OpenFGA — 인가(WSO2-OSS-MAPPING Phase 2 ⑧, §8-102).
#   ★ datastore-uri 에 비밀번호가 들어간다 — db-password 와 **반드시 같은 값**이어야
#   한다. postgres-bootstrap 은 db-password 로 롤을 만들고 OpenFGA 는 URI 로
#   접속하므로, 둘이 어긋나면 인증 실패가 난다.
#   ★ preshared-key 가 없으면 OPENFGA_AUTHN_METHOD=preshared 가 기동하지 않는다.
OPENFGA_PW=$(gen)
mk openfga-secret     "db-password=$OPENFGA_PW" \n                      "datastore-uri=postgres://openfga:${OPENFGA_PW}@postgresql-headless:5432/openfga?sslmode=disable" \n                      "preshared-key=$(gen 32)"

# DefectDojo — Django SECRET_KEY 와 자격 3종.
#   credential-aes-256-key 는 DB 에 저장하는 연동 자격을 암호화하는 키다.
#   분실하면 저장된 연동 자격을 복호화할 수 없다.
DD_ADMIN=$(gen)
mk defectdojo-secret "db-password=$(gen)" \
                     "secret-key=$(gen 50)" \
                     "credential-aes-256-key=$(gen 50)" \
                     "admin-password=$DD_ADMIN"

# Caldera — 운영자/공격자 API 키와 로그인 2종.
#   ADR-030: dev/local 전용, prod 배포 금지. 에이전트는 기본 미배포다.
CAL_RED=$(gen); CAL_BLUE=$(gen)
mk caldera-secret "api-key-red=$(gen 32)" \
                  "api-key-blue=$(gen 32)" \
                  "red-password=$CAL_RED" \
                  "blue-password=$CAL_BLUE"
# ── 여기서 만들지 않는 시크릿 ──────────────────────────────────────
# `gitlab-registry-secret`(kubernetes.io/dockerconfigjson)은 이 스크립트가
# 만들지 않는다. 난수가 아니라 **GitLab 이 발급하는 배포 토큰**이라
# GitLab 이 떠 있어야만 만들 수 있다:
#     local/gitlab-registry-bootstrap.sh --secret
# ★ GitLab 을 다시 세우면 반드시 다시 돌릴 것 — 그러지 않으면 build-images.sh
#   의 push 가 "invalid username/password" 로 죽고, Trivy 가 로컬 빌드
#   이미지 9종을 스캔하지 못한다(§8-79).
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
printf "  Jenkins    admin / %s\n"           "$JK_ADMIN"
printf "  DefectDojo admin / %s\n"        "$DD_ADMIN"
printf "  Caldera    red / %s   blue / %s\n" "$CAL_RED" "$CAL_BLUE"
echo
echo "[secrets] 생성 결과"
kubectl -n "$NS" get secret -l app.kubernetes.io/part-of=oneinchmarket
