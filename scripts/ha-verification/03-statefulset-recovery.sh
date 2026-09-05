#!/usr/bin/env bash
# HA-3: StatefulSet 복구 — 파드를 죽이고 PVC 재바인딩·복구 시간을 잰다
#
# ★ 단일 노드에서도 의미가 있다. 여기서 재는 것은 "다른 노드로 옮겨가는가"
#   가 아니라 **"같은 PVC 를 다시 물고 데이터가 남아 있는가"** 이며,
#   그것은 노드 수와 무관하다. 다중 노드로 가면 여기에 재배치가 더해진다.
#
# 실행: KUBECTL="sudo k3s kubectl" ./03-statefulset-recovery.sh [namespace] [sts]

set -uo pipefail
K="${KUBECTL:-kubectl}"
NS="${1:-local}"
STS="${2:-postgresql}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo "=== HA-3: StatefulSet 복구 ($NS/$STS) ==="
$K -n "$NS" get sts "$STS" >/dev/null 2>&1 || { printf "${YELLOW}[SKIP]${NC} StatefulSet %s 없음\n" "$STS"; exit 0; }

POD="${STS}-0"
PVC=$($K -n "$NS" get pod "$POD" -o jsonpath='{.spec.volumes[?(@.persistentVolumeClaim)].persistentVolumeClaim.claimName}' 2>/dev/null | awk '{print $1}')
PV_BEFORE=$($K -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
UID_BEFORE=$($K -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}' 2>/dev/null)
echo "  파드 $POD · PVC ${PVC:-없음} · PV ${PV_BEFORE:-없음}"

echo "  죽인다..."
START=$(date +%s)
$K -n "$NS" delete pod "$POD" --wait=false >/dev/null 2>&1

READY=""
for i in $(seq 1 60); do
  U=$($K -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
  R=$($K -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
  if [ -n "$U" ] && [ "$U" != "$UID_BEFORE" ] && [ "$R" = "true" ]; then READY=1; break; fi
  sleep 5
done
END=$(date +%s); ELAPSED=$((END-START))

if [ -z "$READY" ]; then
  printf "${RED}HA-3 실패${NC} — %ds 안에 Ready 로 돌아오지 못했다\n" "$ELAPSED"
  $K -n "$NS" get pod "$POD" 2>/dev/null
  exit 1
fi

PV_AFTER=$($K -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
echo "  복구 시간: ${ELAPSED}s"
echo "  PV: ${PV_BEFORE:-없음} → ${PV_AFTER:-없음}"

if [ -n "$PVC" ] && [ "$PV_BEFORE" != "$PV_AFTER" ]; then
  printf "${RED}HA-3 실패${NC} — **PV 가 바뀌었다.** 새 빈 볼륨을 물었다는 뜻이다\n"
  exit 1
fi
printf "${GREEN}HA-3 통과${NC} — %ds 만에 같은 PV(%s)를 다시 물고 Ready\n" "$ELAPSED" "${PV_AFTER:-N/A}"
