#!/usr/bin/env bash
# ESO 가 OpenBao 를 읽도록 준비한다 — KV 마운트 · 최소 권한 정책 · 전용 토큰
#
# ★ root 토큰을 ESO 에 주지 않는다. 정책 `eso-read` 는 `oim/data/*` 읽기만 갖는다.
#   root 를 주면 시크릿 원천을 OpenBao 로 옮긴 이득이 상당 부분 사라진다 —
#   한 자격이 새면 전부가 새는 상태로 돌아간다(§8-44 의 전례).
#
# ★ 여러 번 돌려도 안전하다. 다만 **토큰은 돌릴 때마다 새로 발급**된다 —
#   기존 토큰은 그대로 살아 있으므로 회수하려면 별도 작업이 필요하다.
#
# 사용
#   local/openbao-eso-setup.sh
set -Eeuo pipefail
trap 'echo "[eso][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

NS="${NS:-local}"
ESO_NS="${ESO_NS:-external-secrets}"
POD="${POD:-openbao-0}"
MOUNT="${MOUNT:-oim}"
log() { echo "[eso] $*"; }

# root 토큰을 파일로만 다룬다 — 셸 변수·프로세스 인자에 남기지 않는다.
kubectl -n "$NS" get secret openbao-keys -o json > /tmp/bao-keys.json
python3 -c 'import base64,json,sys;d=json.load(open("/tmp/bao-keys.json"))["data"];sys.stdout.write(base64.b64decode(d["root-token"]).decode())' > /tmp/bao-root.txt

B() {
  kubectl -n "$NS" exec -i "$POD" -c openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 \
    sh -c 'read -r T; export BAO_TOKEN="$T"; shift 0; eval "$0"' "$1" < /tmp/bao-root.txt
}

log "KV v2 마운트 확인 (${MOUNT})"
if B "bao secrets list -format=json | grep -q '\"${MOUNT}/\"'" ; then
  log "  이미 있다"
else
  B "bao secrets enable -path=${MOUNT} -version=2 kv" >/dev/null
  log "  생성했다"
fi

log "정책 eso-read 작성 (읽기 전용)"
B "cat > /tmp/p.hcl <<'EOP'
path \"${MOUNT}/data/*\"     { capabilities = [\"read\"] }
path \"${MOUNT}/metadata/*\" { capabilities = [\"read\", \"list\"] }
EOP
bao policy write eso-read /tmp/p.hcl && rm -f /tmp/p.hcl" >/dev/null
log "  완료"

log "전용 토큰 발급 (periodic · 갱신 가능)"
B "bao token create -policy=eso-read -period=768h -format=json" > /tmp/bao-tok.json
python3 -c 'import json,sys;sys.stdout.write(json.load(open("/tmp/bao-tok.json"))["auth"]["client_token"])' > /tmp/bao-eso.txt
kubectl -n "$ESO_NS" create secret generic openbao-eso-token \
  --from-file=token=/tmp/bao-eso.txt --dry-run=client -o yaml | kubectl apply -f - >/dev/null
log "  Secret ${ESO_NS}/openbao-eso-token 갱신 (값은 출력하지 않는다)"

shred -u /tmp/bao-keys.json /tmp/bao-root.txt /tmp/bao-tok.json /tmp/bao-eso.txt 2>/dev/null \
  || rm -f /tmp/bao-keys.json /tmp/bao-root.txt /tmp/bao-tok.json /tmp/bao-eso.txt

log "ClusterSecretStore 상태"
kubectl get clustersecretstore openbao -o jsonpath='{.status.conditions[*].type}={.status.conditions[*].status}{"\n"}' 2>/dev/null || echo "  (아직 없음 — 매니페스트를 적용할 것)"
