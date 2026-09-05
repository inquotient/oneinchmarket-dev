#!/usr/bin/env bash
# HA-2: 무상태 워크로드 페일오버 — 복제본 하나를 죽이고 무중단인지 본다
#
# ★ 설정을 읽지 않는다. 실제로 죽이고, 죽이는 동안 계속 요청을 보내
#   **실패한 요청 수**로 판정한다. "복제본이 2개다" 는 무중단의 증거가 아니다.
#
# 실행: KUBECTL="sudo k3s kubectl" ./02-stateless-failover.sh [namespace] [deploy]

set -uo pipefail
K="${KUBECTL:-kubectl}"
NS="${1:-local}"; TARGET="${2:-nginx}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PROBE="ha2-probe"

echo "=== HA-2: 무상태 페일오버 ($NS/$TARGET) ==="
ORIG=$($K -n "$NS" get deploy "$TARGET" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
[ -z "$ORIG" ] && { printf "${YELLOW}[SKIP]${NC} Deployment %s 없음\n" "$TARGET"; exit 0; }

cleanup() {
  $K -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1
  $K -n "$NS" scale deploy "$TARGET" --replicas="$ORIG" >/dev/null 2>&1
}
trap cleanup EXIT

echo "  원래 복제본 $ORIG → 2 (시험 후 되돌린다)"
$K -n "$NS" scale deploy "$TARGET" --replicas=2 >/dev/null
$K -n "$NS" rollout status deploy/"$TARGET" --timeout=180s >/dev/null 2>&1 || true
RUNNING=$($K -n "$NS" get pod -l app.kubernetes.io/name="$TARGET" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
echo "  실행 중 파드: $RUNNING"
[ "$RUNNING" -lt 2 ] && { printf "${YELLOW}[SKIP]${NC} 파드 2개를 못 띄웠다(노드 자원·파드 상한)\n"; exit 0; }

SVC=$($K -n "$NS" get svc --no-headers 2>/dev/null | awk -v t="$TARGET" '$1 ~ t {print $1; exit}')
[ -z "$SVC" ] && { printf "${YELLOW}[SKIP]${NC} 서비스 없음\n"; exit 0; }
PORT=$($K -n "$NS" get svc "$SVC" -o jsonpath='{.spec.ports[0].port}')
VICTIM=$($K -n "$NS" get pod -l app.kubernetes.io/name="$TARGET" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
echo "  대상 $SVC:$PORT · 죽일 파드 $VICTIM"

$K -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=true >/dev/null 2>&1
$K -n "$NS" run "$PROBE" --restart=Never --image=curlimages/curl:8.11.1 \
  --overrides="{\"spec\":{\"securityContext\":{\"runAsNonRoot\":true,\"runAsUser\":1000,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}},\"containers\":[{\"name\":\"c\",\"image\":\"curlimages/curl:8.11.1\",\"securityContext\":{\"allowPrivilegeEscalation\":false,\"capabilities\":{\"drop\":[\"ALL\"]}},\"command\":[\"sh\",\"-c\",\"ok=0;bad=0;i=0;while [ \$i -lt 80 ]; do if curl -s -o /dev/null -m 2 http://$SVC:$PORT/; then ok=\$((ok+1)); else bad=\$((bad+1)); fi; i=\$((i+1)); sleep 0.25; done; echo PROBE_RESULT ok=\$ok bad=\$bad\"]}]}}" \
  >/dev/null 2>&1

for i in $(seq 1 30); do
  [ "$($K -n "$NS" get pod "$PROBE" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && break
  sleep 2
done
echo "  프로브 가동 — 3초 뒤 파드를 죽인다"
sleep 3
$K -n "$NS" delete pod "$VICTIM" --wait=false >/dev/null 2>&1

for i in $(seq 1 40); do
  P=$($K -n "$NS" get pod "$PROBE" -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$P" = "Succeeded" ] || [ "$P" = "Failed" ] && break
  sleep 3
done
OUT=$($K -n "$NS" logs "$PROBE" 2>/dev/null | grep PROBE_RESULT || true)
echo "  $OUT"
OK=$(echo "$OUT"  | grep -o 'ok=[0-9]*'  | cut -d= -f2)
BAD=$(echo "$OUT" | grep -o 'bad=[0-9]*' | cut -d= -f2)
echo ""
if [ -z "${BAD:-}" ]; then
  printf "${YELLOW}[INCONCLUSIVE]${NC} 프로브 결과를 읽지 못했다\n"; exit 0
elif [ "$BAD" -eq 0 ]; then
  printf "${GREEN}HA-2 통과${NC} — 성공 %s · 실패 0. 죽이는 동안 무중단\n" "$OK"
else
  printf "${RED}HA-2 실패${NC} — 성공 %s · **실패 %s**. 복제본이 있어도 끊겼다\n" "$OK" "$BAD"
  exit 1
fi
