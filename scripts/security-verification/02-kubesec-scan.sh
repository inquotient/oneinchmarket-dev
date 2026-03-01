#!/usr/bin/env bash
# 7-2: kubesec 매니페스트 보안 점수 검증
# 모든 워크로드 YAML의 보안 점수를 정적 분석
# 사전 조건: kubesec 설치 (https://kubesec.io)
# 실행: ./02-kubesec-scan.sh

set -euo pipefail
cd "$(dirname "$0")/../.."

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
