#!/usr/bin/env bash
# 7-3: Trivy 이미지 CVE 스캔 + K8s 매니페스트 스캔
# 사전 조건: trivy 설치 (https://trivy.dev)
# 실행: ./03-trivy-scan.sh

set -euo pipefail
cd "$(dirname "$0")/../.."

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "============================================"
echo "  Trivy 보안 스캔"
echo "============================================"
echo ""

# 사용하는 이미지 목록 추출
IMAGES=$(grep -rh 'image:' kubernetes/base --include='*.yaml' \
  | grep -v '#' \
  | grep -v 'kyverno' \
  | sed 's/.*image:\s*//' \
  | sed 's/"//g' \
  | sort -u)

echo "=== Part 1: 이미지 CVE 스캔 ==="
echo ""

SCAN_PASS=0
SCAN_FAIL=0

for img in $IMAGES; do
  printf "Scanning: %-55s ... " "$img"

  if trivy image --severity HIGH,CRITICAL --exit-code 0 --quiet "$img" > /dev/null 2>&1; then
    VULN_COUNT=$(trivy image --severity HIGH,CRITICAL --format json --quiet "$img" 2>/dev/null \
      | grep -o '"VulnerabilityID"' | wc -l || echo "0")

    if [ "$VULN_COUNT" -eq 0 ]; then
      printf "${GREEN}CLEAN${NC}\n"
      SCAN_PASS=$((SCAN_PASS + 1))
    else
      printf "${YELLOW}%d HIGH/CRITICAL${NC}\n" "$VULN_COUNT"
      SCAN_FAIL=$((SCAN_FAIL + 1))
    fi
  else
    printf "${RED}SCAN FAILED${NC}\n"
    SCAN_FAIL=$((SCAN_FAIL + 1))
  fi
done

echo ""
echo "=== Part 2: K8s 매니페스트 설정 스캔 ==="
echo ""

trivy config --severity HIGH,CRITICAL kubernetes/ 2>/dev/null || true

echo ""
echo "=== Part 3: 파일시스템 시크릿 스캔 ==="
echo ""

trivy fs --security-checks secret --quiet . 2>/dev/null || true

echo ""
echo "============================================"
echo "  이미지 스캔 결과"
echo "============================================"
printf "  ${GREEN}Clean: %d${NC}\n" "$SCAN_PASS"
printf "  ${YELLOW}Vulnerable: %d${NC}\n" "$SCAN_FAIL"
echo "============================================"
