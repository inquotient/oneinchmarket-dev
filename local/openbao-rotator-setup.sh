#!/usr/bin/env bash
# 비밀번호 로테이터가 OpenBao 를 원천으로 쓰도록 준비한다 — 로테이터마다 정책 · Kubernetes auth 역할 (2026-11-06)
#
# ★ 왜: 로테이션 CronJob 은 원래 k8s Secret 을 직접 patch 했다. 그런데 그 Secret 들은 ESO 가
#   OpenBao 에서 1시간마다 덮어쓴다(creationPolicy: Merge). Secret 만 바꾸면 한 시간 안에 옛 값으로
#   돌아가 앱과 DB 의 비밀번호가 갈린다. 그래서 새 값은 **OpenBao 에 쓴다** — 원천이 하나여야 한다.
#
# ★★ 로테이터마다 **자기 KV 경로 하나만** 읽고 고친다. 한 정책으로 전부 열면 로테이터 하나가 새도
#   모든 자격이 샌다(eso-read 를 읽기 전용으로 둔 것과 같은 이유 — openbao-eso-setup.sh).
#   역할도 로테이터 전용 SA 하나에만 묶는다(Gotcha 10 — SA 가 곧 신원이다).
#
# ★ 전제: openbao-init.sh · openbao-eso-setup.sh 가 끝나 있을 것(KV `oim` · auth/kubernetes).
# ★ 여러 번 돌려도 안전하다.
#
# 사용
#   local/openbao-rotator-setup.sh               # ROTATORS 전부
#   ROTATORS="postgresql" local/openbao-rotator-setup.sh
set -Eeuo pipefail
trap 'echo "[rotator][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

NS="${NS:-local}"
POD="${POD:-openbao-0}"
MOUNT="${MOUNT:-oim}"
# 이름 <x> 는 SA rotator-<x> · 역할 rotator-<x> · KV 경로 <x>-secret 로 이어진다(paths() 가 예외를 정한다).
# ★ 새 DB 를 더할 때는 그 CronJob(base/rotation/rotate-<x>.yaml)의 설계가 OpenBao 원천인지 먼저 볼 것.
ROTATORS="${ROTATORS:-postgresql postgresql-apps mariadb mongodb seaweedfs redis}"
# ★ seaweedfs 는 경로가 둘이다 — 소비자 사용자 키(seaweedfs-users)와 root(seaweedfs-secret). 두 CronJob 이 같은 SA 를 쓴다
#   (base/rotation/rotate-seaweedfs.yaml). root 로테이션이 root-password 를 쓴다(사용자 로테이션은 root 를 읽지 않는다).
# ★ postgresql-apps(2026-11-07) — 앱 롤 16개의 Secret 을 읽고 쓰고, superuser(postgresql-secret)는 ALTER ROLE 에
#   필요해서 **읽기만** 한다(ro_paths). 목록은 base/rotation/rotate-postgresql-apps.yaml 의 TABLE 과 같아야 한다.
PG_APPS="keycloak-secret gitlab-secret apicurio-secret hive-metastore-secret ranger-secret glitchtip-secret openreplay-secret dependency-track-secret defectdojo-secret safeline-secret openfga-secret midpoint-secret backstage-secret temporal-secret airflow-secret clickhouse-secret"
paths() { case "$1" in seaweedfs) echo "seaweedfs-users seaweedfs-secret";; redis) echo "redis-users redis-secret";; postgresql-apps) echo "$PG_APPS";; mariadb) echo "mariadb-secret cmmn-api-secret proxysql-secret";; mongodb) echo "mongodb-secret gravitee-secret";; *) echo "$1-secret";; esac; }
ro_paths() { case "$1" in postgresql-apps) echo "postgresql-secret";; *) echo "";; esac; }
log() { echo "[rotator] $*"; }

# root 토큰을 파일로만 다룬다 — 셸 변수·프로세스 인자에 남기지 않는다(openbao-eso-setup.sh 와 같다).
kubectl -n "$NS" get secret openbao-keys -o json > /tmp/bao-keys.json
python3 -c 'import base64,json,sys;d=json.load(open("/tmp/bao-keys.json"))["data"];sys.stdout.write(base64.b64decode(d["root-token"]).decode())' > /tmp/bao-root.txt
cleanup() { shred -u /tmp/bao-keys.json /tmp/bao-root.txt 2>/dev/null || rm -f /tmp/bao-keys.json /tmp/bao-root.txt; }
trap cleanup EXIT

B() {
  kubectl -n "$NS" exec -i "$POD" -c openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 \
    sh -c 'read -r T; export BAO_TOKEN="$T"; eval "$0"' "$1" < /tmp/bao-root.txt
}

B "bao auth list -format=json | grep -q '\"kubernetes/\"'" \
  || { echo "auth/kubernetes 가 없다 — openbao-eso-setup.sh 를 먼저 돌릴 것" >&2; exit 1; }

for r in $ROTATORS; do
  case "$r" in *[!a-z0-9-]*) echo "이름이 이상하다: $r" >&2; exit 1;; esac
  hcl=""
  for path in $(paths "$r"); do
    hcl="${hcl}path \"${MOUNT}/data/${path}\"     { capabilities = [\"read\", \"update\", \"patch\"] }
path \"${MOUNT}/metadata/${path}\" { capabilities = [\"read\"] }
"
  done
  for path in $(ro_paths "$r"); do
    hcl="${hcl}path \"${MOUNT}/data/${path}\"     { capabilities = [\"read\"] }
"
  done
  log "정책 rotator-${r} ($(paths "$r") 읽기·쓰기 · 읽기만: $(ro_paths "$r"))"
  # patch 는 `bao kv patch`(키 일부만 바꾼다) · update 는 put — 다른 키를 지우지 않으려고 patch 를 쓴다.
  B "cat > /tmp/p.hcl <<'EOP'
${hcl}EOP
bao policy write rotator-${r} /tmp/p.hcl && rm -f /tmp/p.hcl" >/dev/null

  log "  역할 rotator-${r} (${NS}/rotator-${r})"
  # ttl 15m — 한 번의 로테이션에 충분하고, 새어도 창이 좁다.
  B "bao write auth/kubernetes/role/rotator-${r} \
       bound_service_account_names=rotator-${r} \
       bound_service_account_namespaces=${NS} \
       policies=rotator-${r} ttl=15m max_ttl=30m" >/dev/null

  # 되읽어 확인한다 — 쓴 것과 다르면 멈춘다(Gotcha 86).
  B "bao read -format=json auth/kubernetes/role/rotator-${r}" \
    | python3 -c "import json,sys;d=json.load(sys.stdin)['data'];assert d['bound_service_account_names']==['rotator-${r}'],d;assert 'rotator-${r}' in d['token_policies'],d;print('  역할 확인 ok')"
  pol=$(B "bao policy read rotator-${r}")
  for path in $(paths "$r"); do
    case "$pol" in *"${MOUNT}/data/${path}\""*) ;; *) echo "정책 rotator-${r} 에 ${path} 가 없다" >&2; exit 1;; esac
  done
  log "  정책 확인 ok ($(paths "$r"))"
done
