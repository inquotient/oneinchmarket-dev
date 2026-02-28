#!/usr/bin/env bash
# 7-9: RBAC 최소 권한 검증
# 사전 조건: kubectl (클러스터 연결 상태)
# 실행: ./09-rbac-audit.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NAMESPACE="${1:-dev}"

echo "============================================"
echo "  RBAC 최소 권한 검증 (namespace: $NAMESPACE)"
echo "============================================"
echo ""

# 1. ServiceAccount 목록
echo "=== 1. ServiceAccount 목록 ==="
kubectl get sa -n "$NAMESPACE" -o custom-columns='NAME:.metadata.name,SECRETS:.secrets[*].name' 2>/dev/null \
  || echo "  Failed to list ServiceAccounts"
echo ""

# 2. Role/RoleBinding 확인
echo "=== 2. Role 권한 확인 ==="
ROLES=$(kubectl get roles -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
for role in $ROLES; do
  printf "\n${BLUE}Role: %s${NC}\n" "$role"
  kubectl get role "$role" -n "$NAMESPACE" -o jsonpath='{range .rules[*]}  resources: {.resources}  verbs: {.verbs}{"\n"}{end}' 2>/dev/null
done
echo ""

# 3. ClusterRole 확인 (프로젝트 관련만)
echo "=== 3. ClusterRole 확인 (oneinchmarket) ==="
CLUSTER_ROLES=$(kubectl get clusterroles -l app.kubernetes.io/part-of=oneinchmarket \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

for cr in $CLUSTER_ROLES; do
  printf "\n${BLUE}ClusterRole: %s${NC}\n" "$cr"
  kubectl get clusterrole "$cr" -o jsonpath='{range .rules[*]}  resources: {.resources}  verbs: {.verbs}{"\n"}{end}' 2>/dev/null
done
echo ""

# 4. 과도한 권한 검출
echo "=== 4. 과도한 권한 검출 ==="

# 4-1. wildcard(*) 사용 확인
echo "--- 4-1. Wildcard(*) 권한 ---"
WILD_ROLES=$(kubectl get roles,clusterroles -A -o json 2>/dev/null \
  | grep -l '"*"' 2>/dev/null || true)
if [ -z "$WILD_ROLES" ]; then
  printf "${GREEN}[OK]${NC}   Wildcard 권한 없음\n"
else
  printf "${YELLOW}[WARN]${NC} Wildcard 권한 발견\n"
fi

# 4-2. secrets verb 확인
echo "--- 4-2. Secret 접근 권한 ---"
for role in $(kubectl get roles -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  SECRET_VERBS=$(kubectl get role "$role" -n "$NAMESPACE" -o json 2>/dev/null \
    | grep -A5 '"secrets"' | grep '"verbs"' || true)
  if [ -n "$SECRET_VERBS" ]; then
    VERBS=$(echo "$SECRET_VERBS" | grep -o '\[.*\]')
    if echo "$VERBS" | grep -q '"delete"\|"create"\|"\*"'; then
      printf "${RED}[WARN]${NC} %-25s secret 권한 과도: %s\n" "$role" "$VERBS"
    else
      printf "${GREEN}[OK]${NC}   %-25s secret 권한 적절: %s\n" "$role" "$VERBS"
    fi
  fi
done

# 4-3. default ServiceAccount 사용 확인
echo ""
echo "--- 4-3. default ServiceAccount 사용 Pod ---"
DEFAULT_SA_PODS=$(kubectl get pods -n "$NAMESPACE" \
  -o jsonpath='{range .items[?(@.spec.serviceAccountName=="default")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
if [ -z "$DEFAULT_SA_PODS" ]; then
  printf "${GREEN}[OK]${NC}   모든 Pod가 전용 ServiceAccount 사용\n"
else
  printf "${YELLOW}[WARN]${NC} default SA 사용 Pod:\n"
  echo "$DEFAULT_SA_PODS" | while read -r pod; do
    printf "         - %s\n" "$pod"
  done
fi

echo ""

# 5. automountServiceAccountToken 확인
echo "=== 5. SA Token 자동 마운트 확인 ==="
AUTOMOUNT_PODS=$(kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null \
  | grep -c '"automountServiceAccountToken": true' || echo "0")
TOTAL_PODS=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
printf "  Pod 총 수: %s\n" "$TOTAL_PODS"
printf "  SA Token 자동 마운트: %s\n" "$AUTOMOUNT_PODS"
if [ "$AUTOMOUNT_PODS" -gt 0 ]; then
  printf "${YELLOW}[WARN]${NC} 불필요한 SA Token 마운트가 있을 수 있음\n"
  echo "         automountServiceAccountToken: false 설정 검토"
fi

echo ""
echo "============================================"
echo "  RBAC Audit 완료"
echo "============================================"
echo ""
echo "  권장사항:"
echo "  1. Secret 접근: get, patch만 허용 (delete, create 불가)"
echo "  2. 모든 워크로드에 전용 ServiceAccount 할당"
echo "  3. Wildcard(*) 권한 사용 금지"
echo "  4. 불필요한 Pod에서 automountServiceAccountToken: false"
echo "============================================"
