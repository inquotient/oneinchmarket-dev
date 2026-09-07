#!/usr/bin/env bash
# ESO 가 OpenBao 를 읽도록 준비한다 — KV 마운트 · 정책 · Kubernetes auth
#
# ★ root 토큰을 ESO 에 주지 않는다. 정책 `eso-read` 는 `oim/data/*` 읽기만 갖는다.
#   root 를 주면 시크릿 원천을 OpenBao 로 옮긴 이득이 상당 부분 사라진다 —
#   한 자격이 새면 전부가 새는 상태로 돌아간다(§8-44 의 전례).
#
# ★★ 인증은 **Kubernetes auth method** 다. 장기 토큰을 두지 않는다 —
#   ESO 의 ServiceAccount 가 곧 신원이고 OpenBao 가 TokenReview 로 검증한다.
#   토큰은 로그인할 때마다 짧은 수명으로 발급되므로 새어도 창이 좁다.
#   전제: OpenBao SA 에 `automountServiceAccountToken: true` 와
#         ClusterRoleBinding(system:auth-delegator). 매니페스트에 있다.
#
# ★ 여러 번 돌려도 안전하다.
#
# 사용
#   local/openbao-eso-setup.sh
set -Eeuo pipefail
trap 'echo "[eso][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

NS="${NS:-local}"
ESO_NS="${ESO_NS:-external-secrets}"
ESO_SA="${ESO_SA:-external-secrets}"
POD="${POD:-openbao-0}"
MOUNT="${MOUNT:-oim}"
ROLE="${ROLE:-eso}"
log() { echo "[eso] $*"; }

# root 토큰을 파일로만 다룬다 — 셸 변수·프로세스 인자에 남기지 않는다.
kubectl -n "$NS" get secret openbao-keys -o json > /tmp/bao-keys.json
python3 -c 'import base64,json,sys;d=json.load(open("/tmp/bao-keys.json"))["data"];sys.stdout.write(base64.b64decode(d["root-token"]).decode())' > /tmp/bao-root.txt

# 셸 조각을 stdin 의 토큰과 함께 컨테이너에서 실행한다.
B() {
  kubectl -n "$NS" exec -i "$POD" -c openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 \
    sh -c 'read -r T; export BAO_TOKEN="$T"; eval "$0"' "$1" < /tmp/bao-root.txt
}

log "KV v2 마운트 (${MOUNT})"
B "bao secrets list -format=json | grep -q '\"${MOUNT}/\"' || bao secrets enable -path=${MOUNT} -version=2 kv" >/dev/null

log "정책 eso-read (읽기 전용)"
B "cat > /tmp/p.hcl <<'EOP'
path \"${MOUNT}/data/*\"     { capabilities = [\"read\"] }
path \"${MOUNT}/metadata/*\" { capabilities = [\"read\", \"list\"] }
EOP
bao policy write eso-read /tmp/p.hcl && rm -f /tmp/p.hcl" >/dev/null

log "Kubernetes auth method 활성화"
B "bao auth list -format=json | grep -q '\"kubernetes/\"' || bao auth enable kubernetes" >/dev/null

log "  auth/kubernetes/config"
# ★ kubernetes_host 만 준다. OpenBao 가 **자기 SA 토큰**으로 TokenReview 를
#   호출하므로 별도 reviewer 토큰이 필요 없다(그래서 SA 마운트가 전제다).
#   ★ 클러스터 CA 를 명시하지 않으면 파드의 기본 CA 번들을 쓴다.
B "bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc" >/dev/null

log "  역할 ${ROLE} (${ESO_NS}/${ESO_SA} → eso-read)"
# ★ bound_service_account_* 를 좁게 둔다. 넓히면 그 네임스페이스의 아무 SA 나
#   이 정책을 얻는다 — ambient 에서 SA 가 곧 신원인 것과 같은 원리다(Gotcha 10).
B "bao write auth/kubernetes/role/${ROLE} \
     bound_service_account_names=${ESO_SA} \
     bound_service_account_namespaces=${ESO_NS} \
     policies=eso-read ttl=1h max_ttl=4h" >/dev/null

shred -u /tmp/bao-keys.json /tmp/bao-root.txt 2>/dev/null || rm -f /tmp/bao-keys.json /tmp/bao-root.txt

# ★ 장기 토큰이 남아 있으면 지운다. 남겨 두면 ClusterSecretStore 가 kubernetes
#   auth 로 바뀐 뒤에도 **쓰이지 않는 유효한 자격**이 계속 존재한다.
if kubectl -n "$ESO_NS" get secret openbao-eso-token >/dev/null 2>&1; then
  log "낡은 장기 토큰 Secret 제거"
  kubectl -n "$ESO_NS" delete secret openbao-eso-token >/dev/null
fi

log "ClusterSecretStore 상태"
kubectl get clustersecretstore openbao \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{"\n"}{end}' 2>/dev/null \
  || echo "  (아직 없음 — 매니페스트를 적용할 것)"
