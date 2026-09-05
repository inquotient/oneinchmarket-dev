#!/usr/bin/env bash
# OneinchMarket v2 — HA·장애내구성 검증 전체 실행
#
# 위협 모델은 docs/LOCAL-DEPLOYMENT.md §11-0 에서 정했다:
#   범위 안  VM·노드 장애 · 드레인 · 롤링 업그레이드 · 논리 손상
#   범위 밖  물리 디스크 · 호스트 · 전원 (물리 호스트가 한 대라 막을 수 없다)
#
# 실행: KUBECTL="sudo k3s kubectl" ./run-all.sh [namespace]
#
#   HA-1  복제본 수 가드 (§11-3 회귀 방지)   — 파괴적이지 않음
#   HA-2  무상태 페일오버                     — ★ 파드를 죽인다
#   HA-3  StatefulSet 복구                    — ★ 파드를 죽인다
#   HA-4  다중 노드가 있어야 하는 시험 목록   — 아무것도 하지 않음

set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
NS="${1:-local}"
GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   OneinchMarket v2 — HA · 장애내구성 검증        ║"
echo "║   Namespace: ${NS}"
echo "║   Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo "╚══════════════════════════════════════════════════╝"
echo ""
printf "${BOLD}★ HA-2·HA-3 은 실제로 파드를 죽인다.${NC} 운영 클러스터에서 돌리지 말 것.\n\n"

# ── 사전 점검 — 시험이 부수 피해를 내지 않게 ──────────────────────
#
# ★ 실측으로 겪은 것: 노드가 107/110 파드일 때 HA-2 의 프로브 파드가
#   상한을 넘겨 **과금 CronJob 2개가 `Too many pods` 로 스케줄되지 못했다.**
#   시험 대상이 아닌 워크로드가 시험 때문에 죽는 것은 받아들일 수 없다.
#   HA-2 는 프로브 1개 + 복제본 1개, 도합 2자리를 쓴다.
K="${KUBECTL:-kubectl}"
NODE=$($K get node --no-headers 2>/dev/null | head -1 | awk '{print $1}')
if [ -n "${NODE:-}" ]; then
  CAP=$($K get node "$NODE" -o jsonpath='{.status.allocatable.pods}' 2>/dev/null)
  # -A 출력은 NAMESPACE NAME READY STATUS ... 이므로 STATUS 는 $4 다.
  # 종료된 파드는 노드 상한을 차지하지 않으므로 빼야 한다.
  CUR=$($K get pod -A --no-headers 2>/dev/null | awk '$4!="Completed" && $4!="Succeeded"' | wc -l)
  HEAD=$(( ${CAP:-110} - ${CUR:-0} ))
  printf "파드 여유: %s / %s (여유 %s)
" "$CUR" "${CAP:-?}" "$HEAD"
  if [ "$HEAD" -lt 3 ]; then
    printf "${RED}중단${NC} — 파드 여유가 %s 자리다. HA-2 가 2자리를 쓰므로 다른
" "$HEAD"
    printf "        워크로드가 스케줄되지 못한다. 여유를 3자리 이상 만들고 다시 돌릴 것.
"
    exit 1
  fi
  echo ""
fi

PASS=0; FAIL=0
run() {
  local script="$1"; shift
  echo "────────────────────────────────────────────────────"
  if bash "$DIR/$script" "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
  echo ""
}

run 01-replica-guard.sh
run 02-stateless-failover.sh "$NS" nginx
run 03-statefulset-recovery.sh "$NS" postgresql
run 04-multinode-gaps.sh "$NS"

echo "════════════════════════════════════════════════════"
printf "통과 ${GREEN}%d${NC} · 실패 ${RED}%d${NC}\n" "$PASS" "$FAIL"
printf "\n${BOLD}주의${NC} — 통과 건수는 'HA 가 된다' 는 뜻이 아니다.\n"
printf "HA-4 의 GAP 목록이 비어야 그렇게 말할 수 있다.\n"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
