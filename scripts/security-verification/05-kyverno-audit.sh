#!/usr/bin/env bash
# 7-5: Kyverno Audit 리포트 확인
# 사전 조건: kubectl + Kyverno 설치 상태
# 실행: ./05-kyverno-audit.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "============================================"
echo "  Kyverno 정책 Audit 리포트"
echo "============================================"
echo ""

# 1. ClusterPolicy 존재 확인
echo "=== 1. ClusterPolicy 목록 ==="
POLICIES=(
  "disallow-root-user"
  "require-resource-limits"
  "disallow-latest-tag"
  "disallow-privilege-escalation"
  "require-labels"
  "require-probes"
)

for policy in "${POLICIES[@]}"; do
  if kubectl get clusterpolicy "$policy" > /dev/null 2>&1; then
    ACTION=$(kubectl get clusterpolicy "$policy" -o jsonpath='{.spec.validationFailureAction}')
    printf "${GREEN}[OK]${NC}   %-35s action: %s\n" "$policy" "$ACTION"
  else
    printf "${RED}[MISS]${NC} %-35s NOT FOUND\n" "$policy"
  fi
done

echo ""

# 2. Policy Report 확인
echo "=== 2. PolicyReport 요약 ==="
for ns in dev prod; do
  echo ""
  printf "${BLUE}Namespace: %s${NC}\n" "$ns"

  if kubectl get policyreport -n "$ns" > /dev/null 2>&1; then
    kubectl get policyreport -n "$ns" -o custom-columns=\
'NAME:.metadata.name,PASS:.summary.pass,FAIL:.summary.fail,WARN:.summary.warn,ERROR:.summary.error,SKIP:.summary.skip' \
      2>/dev/null || echo "  No policy reports found"
  else
    echo "  PolicyReport CRD not available"
  fi
done

echo ""

# 3. ClusterPolicyReport 확인
echo "=== 3. ClusterPolicyReport ==="
if kubectl get clusterpolicyreport > /dev/null 2>&1; then
  kubectl get clusterpolicyreport -o custom-columns=\
'NAME:.metadata.name,PASS:.summary.pass,FAIL:.summary.fail,WARN:.summary.warn' \
    2>/dev/null || echo "  No cluster policy reports"
else
  echo "  ClusterPolicyReport CRD not available"
fi

echo ""

# 4. 위반 Pod 확인 (Audit 모드)
echo "=== 4. 정책 위반 이벤트 (최근 10건) ==="
kubectl get events --field-selector reason=PolicyViolation \
  --sort-by='.lastTimestamp' 2>/dev/null \
  | tail -10 || echo "  No policy violation events"

echo ""

# 5. dry-run 테스트 - 위반 Pod 배포 시도
echo "=== 5. Dry-run 정책 검증 ==="

# root 컨테이너 차단 테스트
echo -n "  disallow-root-user: "
RESULT=$(kubectl run test-root --image=nginx --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsUser":0}}}' \
  --dry-run=server 2>&1 || true)
if echo "$RESULT" | grep -qi "blocked\|denied\|violat"; then
  printf "${GREEN}ENFORCED${NC}\n"
else
  printf "${YELLOW}NOT ENFORCED (Audit mode?)${NC}\n"
fi

# 리소스 제한 없는 Pod 차단 테스트
echo -n "  require-resource-limits: "
RESULT=$(kubectl run test-nolimit --image=nginx --restart=Never \
  --dry-run=server 2>&1 || true)
if echo "$RESULT" | grep -qi "blocked\|denied\|violat\|resource"; then
  printf "${GREEN}ENFORCED${NC}\n"
else
  printf "${YELLOW}NOT ENFORCED (Audit mode?)${NC}\n"
fi

# 권한 상승 차단 테스트
echo -n "  disallow-privilege-escalation: "
RESULT=$(kubectl run test-privesc --image=nginx --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"test","image":"nginx","securityContext":{"allowPrivilegeEscalation":true}}]}}' \
  --dry-run=server 2>&1 || true)
if echo "$RESULT" | grep -qi "blocked\|denied\|violat\|privilege"; then
  printf "${GREEN}ENFORCED${NC}\n"
else
  printf "${YELLOW}NOT ENFORCED (Audit mode?)${NC}\n"
fi

echo ""
echo "============================================"
echo "  Kyverno Audit 완료"
echo "============================================"
