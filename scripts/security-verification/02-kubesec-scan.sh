#!/usr/bin/env bash
# 7-2: kubesec 매니페스트 보안 점수 검증
# 모든 워크로드 YAML의 보안 점수를 정적 분석
# 사전 조건: kubesec 설치 (https://kubesec.io)
# 실행: ./02-kubesec-scan.sh

set -euo pipefail
cd "$(dirname "$0")/../.."

# ★ 도구가 없는 것을 "점수 N/A = FAIL" 로 적지 않는다 — 그것은 측정하지
#   못한 것이다. 옛 판은 kubesec 이 없으면 **모든 파일을 FAIL** 로 세어
#   exit 1 을 돌려줬고, 그러면 빨간불이 상수가 되어 사람이 배경으로 읽는다
#   (Gotcha 73·90). 종료 코드 2 는 "측정 불가" 를 뜻한다.
if ! command -v kubesec >/dev/null 2>&1; then
  echo "[측정 불가] kubesec 이 설치되어 있지 않다 (https://kubesec.io)"
  echo "            설치한 뒤 다시 돌릴 것. 이것은 통과가 아니다."
  exit 2
fi

PASS=0
WARN=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "============================================"
echo "  kubesec 매니페스트 보안 점수 검증"
echo "============================================"
echo ""

# StatefulSet, Deployment, DaemonSet, CronJob 파일 스캔
for file in $(find kubernetes/base -name '*-statefulset.yaml' -o -name '*-deployment.yaml' -o -name '*-daemonset.yaml' -o -name 'rotate-*.yaml' | sort); do
  TOTAL=$((TOTAL + 1))
  RESULT=$(kubesec scan "$file" 2>/dev/null || echo '[{"score": -1, "message": "scan failed"}]')

  SCORE=$(echo "$RESULT" | grep -o '"score":[0-9\-]*' | head -1 | cut -d: -f2)

  if [ -z "$SCORE" ] || [ "$SCORE" = "-1" ]; then
    printf "${RED}[FAIL]${NC} %-60s score: N/A\n" "$file"
    FAIL=$((FAIL + 1))
  elif [ "$SCORE" -ge 5 ]; then
    printf "${GREEN}[PASS]${NC} %-60s score: %s\n" "$file" "$SCORE"
    PASS=$((PASS + 1))
  elif [ "$SCORE" -ge 0 ]; then
    printf "${YELLOW}[WARN]${NC} %-60s score: %s\n" "$file" "$SCORE"
    WARN=$((WARN + 1))
  else
    printf "${RED}[FAIL]${NC} %-60s score: %s\n" "$file" "$SCORE"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "============================================"
echo "  결과 요약"
echo "============================================"
printf "  총 파일: %d\n" "$TOTAL"
printf "  ${GREEN}PASS (score >= 5): %d${NC}\n" "$PASS"
printf "  ${YELLOW}WARN (score 0-4):  %d${NC}\n" "$WARN"
printf "  ${RED}FAIL (score < 0):  %d${NC}\n" "$FAIL"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "FAIL 항목에 대해 개별 상세 분석:"
  echo "  kubesec scan <파일명> | jq '.[] | .scoring.advise'"
  exit 1
fi
