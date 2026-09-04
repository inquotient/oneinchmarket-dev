#!/usr/bin/env bash
# API 과금 계량용 액세스 로그 제공자를 Istio meshConfig 에 넣는다.
#
# ★ 왜 별도 스크립트인가 — Istio 는 istioctl 로 설치되어 kustomize 오버레이가
#   닿지 않는다(install-operators.sh 가 자원 설정을 거기서 넣는 것과 같은 이유).
#   그리고 meshConfig 는 ConfigMap 안의 **YAML 문자열**이라 kubectl patch 로
#   문자열 조작을 하면 조용히 깨진다. 파싱해서 병합한다.
#
# ★ logFormat 은 labels 가 아니라 text 다. labels 는 값을 전부 문자열로
#   만들어 status·duration 이 "200" 처럼 나온다 —
#   contracts/schemas/api-usage-event.json 이 정수를 요구하므로 맞지 않는다.
set -euo pipefail

PROVIDER=api-usage-json

# 계약과 1:1 로 대응한다. 바꿀 때는 계약을 먼저 고칠 것(ADR-067).
#   id      멱등성 키. Kafka 가 at-least-once 라 이 값으로 중복을 제거하지
#           않으면 고객에게 과다 청구한다.
#   subject 청구 대상(조직/테넌트). 헤더가 없으면 Envoy 가 `-` 를 넣는다 —
#           소비자는 그런 이벤트를 **청구하지 말고 격리**해야 한다.
#   time    관측 시각. 청구 주기 귀속을 이 값이 정한다.
read -r -d '' FMT <<'EOF' || true
{"specversion":"1.0","id":"%REQ(X-REQUEST-ID)%","source":"//gateway.oneinchmarket.local/istio","type":"io.oneinchmarket.api.request.v1","subject":"%REQ(X-OIM-TENANT)%","time":"%START_TIME(%Y-%m-%dT%H:%M:%S.%3fZ)%","datacontenttype":"application/json","data":{"route":"%ROUTE_NAME%","method":"%REQ(:METHOD)%","status":%RESPONSE_CODE%,"duration_ms":%DURATION%,"request_bytes":%BYTES_RECEIVED%,"response_bytes":%BYTES_SENT%}}
EOF

K="${KUBECTL:-kubectl}"

cur=$($K -n istio-system get configmap istio -o jsonpath='{.data.mesh}')

# ★ 파이썬 스크립트를 파일로 빼서 넘긴다. `python3 - <<PY <<<"$cur"` 처럼
#   stdin 리다이렉션을 둘 두면 뒤엣것이 이겨서 **YAML 이 스크립트로 읽힌다.**
#   실측으로 한 번 물렸다.
cat > /tmp/merge-mesh.py <<'PYEOF'
import os, sys, yaml
mesh = yaml.safe_load(sys.stdin.read()) or {}
provider = os.environ["PROVIDER"]
eps = mesh.setdefault("extensionProviders", [])
eps[:] = [e for e in eps if e.get("name") != provider]
eps.append({
    "name": provider,
    "envoyFileAccessLog": {
        "path": "/dev/stdout",
        "logFormat": {"text": os.environ["FMT"].rstrip("\n") + "\n"},
    },
})
sys.stdout.write(yaml.safe_dump(mesh, default_flow_style=False, sort_keys=True, allow_unicode=True))
PYEOF

merged=$(printf '%s' "$cur" | FMT="$FMT" PROVIDER="$PROVIDER" python3 /tmp/merge-mesh.py)

[ -n "$merged" ] || { echo "[usage-logging] meshConfig 병합 실패 — 중단" >&2; exit 1; }

printf '%s' "$merged" > /tmp/mesh-merged.yaml
$K -n istio-system create configmap istio \
  --from-file=mesh=/tmp/mesh-merged.yaml \
  --dry-run=client -o yaml | \
  $K -n istio-system patch configmap istio --type merge --patch-file /dev/stdin

echo "[usage-logging] 제공자 '${PROVIDER}' 반영. istiod 를 재시작한다."
$K -n istio-system rollout restart deploy/istiod
$K -n istio-system rollout status deploy/istiod --timeout=300s
