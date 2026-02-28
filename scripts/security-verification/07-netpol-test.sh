#!/usr/bin/env bash
# 7-7: NetworkPolicy 허용/차단 트래픽 검증
# 사전 조건: kubectl (클러스터 연결 상태)
# 실행: ./07-netpol-test.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

NAMESPACE="${1:-dev}"

echo "============================================"
echo "  NetworkPolicy 검증 (namespace: $NAMESPACE)"
echo "============================================"
echo ""

# 1. NetworkPolicy 목록 확인
echo "=== 1. NetworkPolicy 목록 ==="
kubectl get networkpolicy -n "$NAMESPACE" 2>/dev/null || echo "  No NetworkPolicies found"
echo ""

# 2. default-deny 정책 확인
echo "=== 2. Default-Deny 정책 확인 ==="
if kubectl get networkpolicy default-deny-all -n "$NAMESPACE" > /dev/null 2>&1; then
  printf "${GREEN}[OK]${NC}   default-deny-all exists\n"
else
  printf "${RED}[MISS]${NC} default-deny-all NOT FOUND - 모든 트래픽이 허용됩니다!\n"
fi
echo ""

# 테스트 Pod 생성 함수
create_test_pod() {
  local name=$1
  local label=$2
  kubectl run "$name" -n "$NAMESPACE" --image=busybox:latest \
    --labels="app.kubernetes.io/name=$label" \
    --restart=Never \
    --overrides='{
      "spec": {
        "securityContext": {"runAsNonRoot": true, "runAsUser": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{
          "name": "test",
          "image": "busybox:latest",
          "command": ["sleep", "120"],
          "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}},
          "resources": {"requests": {"cpu": "10m", "memory": "16Mi"}, "limits": {"cpu": "50m", "memory": "32Mi"}}
        }]
      }
    }' 2>/dev/null || true
}

cleanup() {
  echo ""
  echo "=== 정리 ==="
  kubectl delete pod netpol-source netpol-db-test -n "$NAMESPACE" --grace-period=0 --force 2>/dev/null || true
}
trap cleanup EXIT

# 3. 연결 테스트
echo "=== 3. 연결 테스트 ==="
echo "테스트 Pod 생성 중..."
create_test_pod "netpol-source" "test-source"
create_test_pod "netpol-db-test" "test-db"

echo "Pod 준비 대기 (10초)..."
sleep 10

# 허용되어야 하는 연결 테스트
echo ""
echo "--- 허용 트래픽 테스트 ---"
ALLOWED_TESTS=(
  "postgresql-headless:5432:PostgreSQL"
  "kafka-headless:9092:Kafka"
  "elasticsearch-es-http:9200:Elasticsearch"
)

for test in "${ALLOWED_TESTS[@]}"; do
  IFS=: read -r host port name <<< "$test"
  printf "  %-20s (%s:%s) ... " "$name" "$host" "$port"

  RESULT=$(kubectl exec netpol-source -n "$NAMESPACE" -- \
    timeout 3 sh -c "echo | nc -w 2 $host $port" 2>&1 || true)

  if echo "$RESULT" | grep -qi "timed out\|refused\|unreachable"; then
    printf "${YELLOW}BLOCKED${NC} (서비스 미실행 또는 NetworkPolicy)\n"
  else
    printf "${GREEN}ALLOWED${NC}\n"
  fi
done

# 차단되어야 하는 연결 테스트 (label이 맞지 않는 Pod에서)
echo ""
echo "--- 차단 트래픽 테스트 (비인가 소스) ---"
DENIED_TESTS=(
  "postgresql-headless:5432:PostgreSQL"
  "elasticsearch-es-http:9200:Elasticsearch"
)

for test in "${DENIED_TESTS[@]}"; do
  IFS=: read -r host port name <<< "$test"
  printf "  %-20s (%s:%s) ... " "$name" "$host" "$port"

  RESULT=$(kubectl exec netpol-db-test -n "$NAMESPACE" -- \
    timeout 3 sh -c "echo | nc -w 2 $host $port" 2>&1 || true)

  if echo "$RESULT" | grep -qi "timed out\|refused\|unreachable"; then
    printf "${GREEN}BLOCKED (정상)${NC}\n"
  else
    printf "${RED}ALLOWED (비정상 - 차단 필요)${NC}\n"
  fi
done

echo ""
echo "============================================"
echo "  NetworkPolicy 검증 완료"
echo "============================================"
