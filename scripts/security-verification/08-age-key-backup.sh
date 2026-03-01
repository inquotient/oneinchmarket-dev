#!/usr/bin/env bash
# 7-8: age 키 백업 검증
# SOPS age 키의 안전한 보관 상태를 검증
# 실행: ./08-age-key-backup.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "============================================"
echo "  age 키 백업 검증"
echo "============================================"
echo ""

# 1. .sops.yaml 설정 확인
echo "=== 1. SOPS 설정 확인 ==="
SOPS_CONFIG="$(git rev-parse --show-toplevel)/.sops.yaml"
if [ -f "$SOPS_CONFIG" ]; then
  printf "${GREEN}[OK]${NC}   .sops.yaml 존재\n"
  AGE_KEY=$(grep 'age:' "$SOPS_CONFIG" | sed 's/.*age:\s*//' | tr -d '"' | head -1)
  if [ -n "$AGE_KEY" ] && [ "$AGE_KEY" != "age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ]; then
    printf "${GREEN}[OK]${NC}   age 공개키 설정됨: %s...\n" "${AGE_KEY:0:20}"
  else
    printf "${YELLOW}[WARN]${NC} age 공개키가 placeholder 상태\n"
  fi
else
  printf "${RED}[FAIL]${NC} .sops.yaml 없음\n"
fi
echo ""

# 2. .gitignore에 age 키 제외 확인
echo "=== 2. .gitignore 보호 확인 ==="
GITIGNORE="$(git rev-parse --show-toplevel)/.gitignore"
CHECKS=(
  "keys.txt:age 개인키"
  "*.age:age 파일"
  "*.key:TLS 개인키"
  "*.dec.yaml:SOPS 복호화 파일"
)

for check in "${CHECKS[@]}"; do
  IFS=: read -r pattern desc <<< "$check"
  if grep -q "$pattern" "$GITIGNORE" 2>/dev/null; then
    printf "${GREEN}[OK]${NC}   %-20s → .gitignore에서 제외\n" "$desc"
  else
    printf "${RED}[FAIL]${NC} %-20s → .gitignore에 없음!\n" "$desc"
  fi
done
echo ""

# 3. Git에 민감 파일 추적 여부 확인
echo "=== 3. Git 추적 민감 파일 확인 ==="
SENSITIVE_PATTERNS="\.key$|keys\.txt|\.age$|\.dec\.yaml$|\.pem$"
TRACKED=$(git ls-files | grep -E "$SENSITIVE_PATTERNS" || true)
if [ -z "$TRACKED" ]; then
  printf "${GREEN}[OK]${NC}   Git에 추적되는 민감 파일 없음\n"
else
  printf "${RED}[FAIL]${NC} 다음 민감 파일이 Git에 추적 중:\n"
  echo "$TRACKED" | while read -r f; do
    printf "         - %s\n" "$f"
  done
fi
echo ""

# 4. K8s Secret으로 age 키 저장 확인
echo "=== 4. K8s sops-age Secret 확인 ==="
if kubectl get secret sops-age > /dev/null 2>&1; then
  printf "${GREEN}[OK]${NC}   sops-age Secret 존재\n"
  KEYS=$(kubectl get secret sops-age -o jsonpath='{.data}' | grep -o '"[^"]*":' | tr -d '":')
  printf "         keys: %s\n" "$KEYS"
else
  printf "${YELLOW}[WARN]${NC} sops-age Secret 미생성 (클러스터 배포 전이면 정상)\n"
fi
echo ""

# 5. 암호화된 Secret 파일 확인
echo "=== 5. SOPS 암호화 Secret 파일 확인 ==="
ENC_FILES=$(find "$(git rev-parse --show-toplevel)/kubernetes" -name '*.enc.yaml' | sort)
ENC_COUNT=$(echo "$ENC_FILES" | wc -l)
printf "  암호화 대상 파일: %d개\n" "$ENC_COUNT"

for f in $ENC_FILES; do
  BASENAME=$(basename "$f")
  if grep -q 'sops:' "$f" 2>/dev/null; then
    printf "  ${GREEN}[ENC]${NC}  %s\n" "$BASENAME"
  elif grep -q 'PLACEHOLDER' "$f" 2>/dev/null; then
    printf "  ${YELLOW}[PH]${NC}   %s (placeholder - 암호화 필요)\n" "$BASENAME"
  else
    printf "  ${RED}[RAW]${NC}  %s (평문 - 즉시 암호화 필요!)\n" "$BASENAME"
  fi
done

echo ""
echo "============================================"
echo "  백업 권장사항"
echo "============================================"
echo "  1. age 개인키(keys.txt)를 안전한 오프라인 저장소에 백업"
echo "  2. 백업 위치: 물리 USB + 암호화된 클라우드 볼트"
echo "  3. 키 분실 시 모든 SOPS Secret 복호화 불가"
echo "  4. 정기 검증: age-keygen -y keys.txt 로 공개키 매칭 확인"
echo "============================================"
