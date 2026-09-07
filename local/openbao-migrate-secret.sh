#!/usr/bin/env bash
# 기존 Kubernetes Secret 을 OpenBao 로 옮기고 ExternalSecret 을 생성한다
#
# ★ 왜 점진적인가 — 워크로드 40여 개가 `secretKeyRef` 로 물려 있다. 하나라도
#   키 이름이나 값이 어긋나면 그 파드가 `CreateContainerConfigError` 로 서고,
#   그 시점에는 무엇이 바뀌었는지 추적하기 어렵다. **몇 개씩 옮기고 매번
#   확인한다.**
#
# ★ creationPolicy 는 **Merge** 다. Owner 가 아니다:
#     · Owner 는 기존 Secret 의 소유권을 요구해 이미 있는 것과 충돌한다
#     · Merge 는 키만 갱신하고 Secret 자체는 남긴다 — **ESO 나 OpenBao 가
#       내려가도 워크로드가 계속 돈다.** 되돌리기도 쉽다(ExternalSecret 삭제)
#   전면 이관이 끝나면 Owner 로 바꾸는 것을 검토한다.
#
# ★★ 옮기면 안 되는 것
#     · `openbao-keys` — OpenBao 를 여는 열쇠다. OpenBao 에 넣으면 순환이다
#     · `elasticsearch-es-*` — ECK 오퍼레이터가 소유·회전한다
#     · `*-tls`·인증서류 — cert-manager 가 소유한다
#
# 사용
#   local/openbao-migrate-secret.sh grafana-secret apicurio-secret
#   OUT=kubernetes/overlays/local/external-secrets local/openbao-migrate-secret.sh <name>...
set -Eeuo pipefail
trap 'echo "[migrate][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

NS="${NS:-local}"
POD="${POD:-openbao-0}"
MOUNT="${MOUNT:-oim}"
OUT="${OUT:-kubernetes/overlays/local/external-secrets}"
log() { echo "[migrate] $*"; }

[ $# -gt 0 ] || { echo "사용: $0 <secret-name>..." >&2; exit 1; }

DENY="openbao-keys elasticsearch-es-default-es-config elasticsearch-es-elastic-user"
for n in "$@"; do
  case " $DENY " in
    *" $n "*) echo "[migrate] ★ $n 은 옮기면 안 된다(스크립트 머리말 참조)" >&2; exit 1;;
  esac
done

kubectl -n "$NS" get secret openbao-keys -o json > /tmp/mig-keys.json
python3 -c 'import base64,json,sys;d=json.load(open("/tmp/mig-keys.json"))["data"];sys.stdout.write(base64.b64decode(d["root-token"]).decode())' > /tmp/mig-root.txt

mkdir -p "$OUT"

for NAME in "$@"; do
  log "── ${NAME}"
  kubectl -n "$NS" get secret "$NAME" -o json > /tmp/mig-src.json

  # ★ 값을 셸 변수로 꺼내지 않는다. python 이 kv put 인자열을 파일로 만들고
  #   그 파일을 컨테이너 stdin 으로 넘긴다.
  python3 - "$NAME" <<'PY' > /tmp/mig-cmd.txt
import base64, json, shlex, sys
name = sys.argv[1]
d = json.load(open("/tmp/mig-src.json")).get("data", {})
if not d:
    sys.exit("빈 Secret 이다: " + name)
args = " ".join(f"{k}={shlex.quote(base64.b64decode(v).decode())}" for k, v in sorted(d.items()))
print(f"bao kv put oim/{name} {args}")
PY

  # root 토큰과 명령을 함께 넘긴다(첫 줄 토큰, 나머지 명령).
  { cat /tmp/mig-root.txt; echo; cat /tmp/mig-cmd.txt; } \
    | kubectl -n "$NS" exec -i "$POD" -c openbao -- \
        env BAO_ADDR=http://127.0.0.1:8200 \
        sh -c 'read -r T; export BAO_TOKEN="$T"; read -r C; eval "$C"' >/dev/null
  log "   OpenBao 에 기록"

  # 왕복 검증 — 값을 출력하지 않고 **해시로** 비교한다.
  { cat /tmp/mig-root.txt; echo; } \
    | kubectl -n "$NS" exec -i "$POD" -c openbao -- \
        env BAO_ADDR=http://127.0.0.1:8200 \
        sh -c "read -r T; export BAO_TOKEN=\"\$T\"; bao kv get -format=json ${MOUNT}/${NAME}" > /tmp/mig-back.json
  python3 - "$NAME" <<'PY'
import base64, hashlib, json, sys
name = sys.argv[1]
src = {k: base64.b64decode(v).decode() for k, v in json.load(open("/tmp/mig-src.json"))["data"].items()}
back = json.load(open("/tmp/mig-back.json"))["data"]["data"]
h = lambda m: hashlib.sha256(repr(sorted(m.items())).encode()).hexdigest()[:16]
if h(src) != h(back):
    sys.exit(f"★ 왕복 불일치 {name}: k8s={h(src)} bao={h(back)} keys={sorted(src)} vs {sorted(back)}")
print(f"   왕복 검증 OK (키 {len(src)}개, sha256:{h(src)})")
PY

  cat > "${OUT}/${NAME}.yaml" <<EOF
# ${NAME} — 원천이 OpenBao 로 옮겨졌다(§8-82).
# ★ creationPolicy: Merge — 기존 Secret 을 소유하지 않고 키만 갱신한다.
#   ESO 나 OpenBao 가 내려가도 워크로드가 계속 돈다.
# ★ dataFrom.extract 는 KV 항목의 **모든 키**를 가져온다. 키를 하나씩
#   나열하면 나중에 키가 늘 때 조용히 빠진다.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ${NAME}
  labels:
    app.kubernetes.io/name: ${NAME}
    app.kubernetes.io/component: security
    app.kubernetes.io/part-of: oneinchmarket
    app.kubernetes.io/managed-by: kustomize
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: ${NAME}
    creationPolicy: Merge
  dataFrom:
    - extract:
        key: ${NAME}
EOF
  log "   ${OUT}/${NAME}.yaml 생성"
done

shred -u /tmp/mig-keys.json /tmp/mig-root.txt /tmp/mig-src.json /tmp/mig-cmd.txt /tmp/mig-back.json 2>/dev/null || true
log "완료 — 적용 후 `kubectl -n ${NS} get externalsecret` 로 SecretSynced 를 확인할 것"
