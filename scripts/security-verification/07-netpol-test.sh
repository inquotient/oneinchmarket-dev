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
  "opensearch-headless:9200:OpenSearch"
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
# 형식: host:port:표시명:프로토콜  (프로토콜이 판정 방법을 정한다)
DENIED_TESTS=(
  "postgresql-headless:5432:PostgreSQL:pgsql"
  "opensearch-headless:9200:OpenSearch:https"
)

# ★★ 포트 열림 검사(nc)로 판정하지 말 것 — ambient 메시에서는 거짓 경보가 난다.
#   ztunnel 은 TCP 연결을 15008 에서 받아들인 뒤 HBONE 계층에서 거부하므로
#   nc 는 "연결됨" 으로 끝나고 refused/timed out 문구가 나오지 않는다.
#   실측(2026-09-11): 이 스크립트가 OpenSearch·PostgreSQL 을 둘 다
#   "ALLOWED (비정상)" 으로 보고했지만, 같은 파드에서 프로토콜 계층으로 재니
#   둘 다 차단이었다(curl -> HTTP 000 / exit 35).
#   Gotcha 19 가 부트스트랩 Job 에서 겪은 것과 같은 함정이다.
#   ★ 보안 검증의 거짓 경보는 상수가 되면 사람이 배경으로 읽는다
#     (Gotcha 73·90 과 같은 구조). 그래서 고친다.
for test in "${DENIED_TESTS[@]}"; do
  IFS=: read -r host port name proto <<< "$test"
  printf "  %-20s (%s:%s) ... " "$name" "$host" "$port"

  case "$proto" in
    https|http)
      # 정책이 끊으면 curl 은 연결/TLS 단계에서 실패해 http_code 가 000 이다.
      CODE=$(kubectl exec netpol-db-test -n "$NAMESPACE" -- \
        sh -c "curl -sk -o /dev/null -w '%{http_code}' --max-time 8 ${proto}://${host}:${port}/ 2>/dev/null || echo 000" 2>/dev/null || echo 000)
      if [ "$CODE" = "000" ]; then
        printf "${GREEN}BLOCKED (정상)${NC}\n"
      else
        printf "${RED}ALLOWED (비정상 - 차단 필요, HTTP %s)${NC}\n" "$CODE"
      fi
      ;;
    pgsql)
      # PostgreSQL 에 SSLRequest(8바이트)를 보내면 정상 서버는 'S' 또는 'N'
      # 1바이트로 답한다. 정책이 끊으면 0바이트다.
      N=$(kubectl exec netpol-db-test -n "$NAMESPACE" -- sh -c \
        'exec 3<>/dev/tcp/'"${host}"'/'"${port}"' 2>/dev/null && printf "\000\000\000\010\004\322\026\057" >&3 && timeout 3 head -c1 <&3 | wc -c || echo 0' 2>/dev/null || echo 0)
      N=$(echo "$N" | tr -dc '0-9'); N=${N:-0}
      if [ "$N" -eq 0 ]; then
        printf "${GREEN}BLOCKED (정상)${NC}\n"
      else
        printf "${RED}ALLOWED (비정상 - 차단 필요)${NC}\n"
      fi
      ;;
    *)
      printf "${YELLOW}SKIP (프로토콜 미지정)${NC}\n"
      ;;
  esac
done

echo ""
echo "============================================"
echo "  NetworkPolicy 검증 완료"
echo "============================================"
