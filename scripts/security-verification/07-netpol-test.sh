#!/usr/bin/env bash
# 7-7: NetworkPolicy 검증 — 프로토콜 계층에서 재고, 측정 불가를 통과로 접지 않는다
#
# 사전 조건: kubectl (클러스터 연결 상태)
# 실행: ./07-netpol-test.sh [namespace]
#
# ★★★ 판정은 둘이 아니라 셋이다 — 차단 / 허용 / **측정 불가**.
#   2026-10-07 실측으로 이 스크립트의 옛 판이 셋을 둘로 접고 있었다:
#   차단 시험이 busybox 파드에서 curl 과 bash 의 /dev/tcp 를 쓰는데 busybox
#   에는 둘 다 없고, 그러면 "|| echo 000" / "|| echo 0" 이 전부
#   "BLOCKED (정상)" 으로 수렴한다. 즉 **무엇이 열려 있어도 초록불**이었다.
#   Gotcha 147 이 거짓 경보(열려 있다고 잘못 말함)를 고치면서 그 반대쪽
#   거짓 안심(막혀 있다고 잘못 말함)을 만든 것이다. 뒤쪽이 더 나쁘다 —
#   경보는 사람이 다시 재지만 안심은 재지 않는다.
#
# ★★ 측정 방법은 Gotcha 147 이 정한 것을 따른다 — **응답 바이트를 센다.**
#   ztunnel 은 TCP 를 15008 에서 받아들인 뒤 HBONE 계층에서 거부하므로
#   포트 열림 검사로는 차단이 드러나지 않는다. 그러나 거부되면 **한 바이트도
#   돌아오지 않는다.** 그래서 "요청을 보내고 응답 바이트 수를 센다" 가 유일
#   하게 성립하는 판정이고, busybox 의 nc 만으로 할 수 있다.
#
# ★ 장치 대조군을 먼저 돌린다 — 그것 없이는 "0 바이트" 가 "차단" 인지
#   "내 nc 가 고장" 인지 구분되지 않는다. 대조군은 인그레스 게이트웨이 80
#   이다: allow-ingress-gateway 가 from 을 비워 **모든 출발지**를 허용하므로
#   (Gotcha 185) 정책이 정상이면 반드시 바이트가 돌아온다. 대조군이 0 바이트
#   면 그 뒤를 재지 않고 측정 불가로 보고한다.
#
# 종료 코드: 0 통과 · 1 실패(차단되어야 할 것이 열렸다) · 2 측정 불가

set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

NAMESPACE="${1:-dev}"

# 집계. 측정 불가는 통과로 세지 않는다 — 재지 못한 것을 통과로 적으면
# 이 스크립트가 있으나 마나다.
FAILED=0
UNMEASURED=0

echo "============================================"
echo "  NetworkPolicy 검증 (namespace: $NAMESPACE)"
echo "============================================"
echo ""

# ★ "읽을 수 없다" 와 "없다" 는 다르다. API 에 닿지 못한 것을 "정책이 없다"
#   로 적으면 이 스크립트가 경계하는 바로 그 혼동을 스스로 저지른다.
#   그래서 목록을 읽었는지를 기억해 두고 아래 판정의 전제로 쓴다.
CAN_READ=0
echo "=== 1. NetworkPolicy 목록 ==="
if kubectl get networkpolicy -n "$NAMESPACE" 2>/dev/null; then
  CAN_READ=1
else
  printf "%s[측정 불가]%s 네임스페이스 %s 의 NetworkPolicy 를 읽을 수 없다\n" "$YELLOW" "$NC" "$NAMESPACE"
  echo "           (API 에 닿지 못한 것이다 — 정책이 없다는 뜻이 아니다)"
  UNMEASURED=$((UNMEASURED + 1))
fi
echo ""

# ★ 이름을 추측하지 말 것 — 이 레포의 정책 이름은 default-deny-ingress 다.
#   옛 판은 default-deny-all 을 찾아 **매번 빨간 [MISS] 를 찍었다**(존재하지
#   않는 이름이다. G33 으로 추적되고 있었다). 빨간불이 상수가 되면 사람이
#   배경으로 읽고, 그때는 진짜 구멍도 함께 묻힌다(Gotcha 73·90).
echo "=== 2. Default-Deny 정책 확인 ==="
DENY_NAME="default-deny-ingress"
if [ "$CAN_READ" -ne 1 ]; then
  printf "%s[측정 불가]%s 목록을 읽지 못했으므로 %s 의 유무를 판정하지 않는다\n" "$YELLOW" "$NC" "$DENY_NAME"
  UNMEASURED=$((UNMEASURED + 1))
elif kubectl get networkpolicy "$DENY_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  printf "%s[OK]%s   %s 가 있다\n" "$GREEN" "$NC" "$DENY_NAME"
  TYPES=$(kubectl get networkpolicy "$DENY_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.policyTypes}' 2>/dev/null || echo "")
  SEL=$(kubectl get networkpolicy "$DENY_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.podSelector}' 2>/dev/null || echo "")
  printf "         policyTypes=%s  podSelector=%s\n" "${TYPES:-없음}" "${SEL:-없음}"
  case "$TYPES" in
    *Ingress*) : ;;
    *) printf "%s[FAIL]%s policyTypes 에 Ingress 가 없다 — 이름만 맞고 막지 않는다\n" "$RED" "$NC"
       FAILED=$((FAILED + 1)) ;;
  esac
  case "$TYPES" in
    *Egress*) printf "         (참고) Egress 도 막는다 — 이 레포 기본값과 다르다\n" ;;
    *)        printf "         (참고) Egress 는 막지 않는다 — 의도된 현재 상태다\n" ;;
  esac
else
  printf "%s[MISS]%s %s 를 찾을 수 없다 — 네임스페이스 전체가 열려 있다\n" "$RED" "$NC" "$DENY_NAME"
  FAILED=$((FAILED + 1))
  echo "         (실제로 있는 deny 류:)"
  kubectl get networkpolicy -n "$NAMESPACE" --no-headers 2>/dev/null \
    | awk '$1 ~ /deny/ {printf "           - %s\n", $1}' || true
fi
echo ""

# 측정용 파드. busybox 로 충분하다 — nc 와 printf 만 쓴다.
# ★ 라벨을 주지 않는다: 이 파드는 **비인가 출발지**여야 한다. 라벨을 주면
#   ALLOW 정책이 선택할 수 있고 그러면 차단 시험이 뜻을 잃는다.
PROBE=netpol-probe

create_probe() {
  kubectl run "$PROBE" -n "$NAMESPACE" --image=docker.io/library/busybox:1.37.0 \
    --restart=Never \
    --overrides='{
      "spec": {
        "securityContext": {"runAsNonRoot": true, "runAsUser": 1000, "runAsGroup": 1000,
                            "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{
          "name": "probe",
          "image": "docker.io/library/busybox:1.37.0",
          "command": ["sleep", "300"],
          "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}},
          "resources": {"requests": {"cpu": "10m", "memory": "16Mi"},
                        "limits": {"cpu": "100m", "memory": "64Mi"}}
        }]
      }
    }' >/dev/null 2>&1 || true
}

cleanup() {
  echo ""
  echo "=== 정리 ==="
  kubectl delete pod "$PROBE" -n "$NAMESPACE" --grace-period=0 --force >/dev/null 2>&1 || true
  echo "  측정 파드 삭제"
}
trap cleanup EXIT

echo "=== 3. 측정 파드 준비 ==="
kubectl delete pod "$PROBE" -n "$NAMESPACE" --grace-period=0 --force >/dev/null 2>&1 || true
create_probe
if ! kubectl wait --for=condition=Ready "pod/$PROBE" -n "$NAMESPACE" --timeout=90s >/dev/null 2>&1; then
  printf "%s[측정 불가]%s 측정 파드가 Ready 가 되지 않았다\n" "$YELLOW" "$NC"
  kubectl get pod "$PROBE" -n "$NAMESPACE" -o wide 2>/dev/null || true
  kubectl get events -n "$NAMESPACE" --field-selector "involvedObject.name=$PROBE" \
    -o custom-columns=REASON:.reason,MSG:.message --no-headers 2>/dev/null | tail -5 || true
  echo ""
  echo "============================================"
  printf "  판정: %s측정 불가%s — 연결 시험을 하지 못했다\n" "$YELLOW" "$NC"
  echo "============================================"
  exit 2
fi
printf "%s[OK]%s   측정 파드 Ready\n" "$GREEN" "$NC"

# ★ 측정 도구가 실제로 있는지 먼저 확인한다. 없으면 **측정 불가**이고,
#   그것을 차단으로 적지 않는다 — 옛 판이 정확히 그 실수를 했다.
if ! kubectl exec "$PROBE" -n "$NAMESPACE" -- sh -c 'command -v nc >/dev/null' 2>/dev/null; then
  printf "%s[측정 불가]%s 파드 안에 nc 가 없다 — 판정 방법이 성립하지 않는다\n" "$YELLOW" "$NC"
  exit 2
fi
printf "%s[OK]%s   nc 있음\n" "$GREEN" "$NC"

# ★★★ 하드 타임아웃이 **필수**다 — 측정이 멈출 수 있기 때문이다.
#   실측(2026-10-09): opensearch-headless:9200 프로브가 **끝나지 않았다.**
#   ztunnel 은 TCP 를 받아들인 뒤 HBONE 계층에서 거부하면서 연결을 닫지 않고
#   (Gotcha 147), 그러면 busybox 의 -w 는 발동하지 않는다. 바깥에서 죽이면
#   kubectl exec 가 137 을 돌려주고 set -e 가 스크립트를 거기서 끝낸다 —
#   실제로 그렇게 rc=137 로 죽었다. **멈추지 않는 측정은 측정이 아니다.**
if ! kubectl exec "$PROBE" -n "$NAMESPACE" -- sh -c 'command -v timeout >/dev/null' 2>/dev/null; then
  printf "%s[측정 불가]%s 파드 안에 timeout 이 없다 — 프로브가 멈출 수 있어 시험하지 않는다\n" "$YELLOW" "$NC"
  exit 2
fi
printf "%s[OK]%s   timeout 있음 (프로브가 멈추지 않는다)\n" "$GREEN" "$NC"
echo ""

# 응답 바이트를 센다. 0 이면 상대가 한 마디도 하지 않은 것이다.
#   $1 호스트  $2 포트  $3 보낼 바이트(printf 형식)
#
# ★★★ 2026-10-09: 이 함수에 결함이 둘 있었고, 둘 다 **거짓 안심**을 만든다.
#   ① busybox 의 nc 는 **stdin 이 EOF 되면 응답을 읽지 않고 끝낸다.** 그래서
#      'printf ... | nc -w 5 host port | wc -c' 는 상대가 멀쩡히 답해도
#      **언제나 0 바이트**였다. 차단 시험만 보면 "0 = 차단" 이 전부 성립해
#      **무엇이 열려 있어도 초록불**이 된다.
#   ② exec 가 실패하거나 프로브가 끝나지 않은 것을 0 으로 돌려주면 그것도
#      차단으로 읽힌다. 그래서 이 함수는 **숫자 또는 ERR** 을 돌려주고,
#      호출부가 ERR 를 측정 불가로 적는다.
# ★★ 실측으로 방법을 골랐다(2026-10-09, local):
#      nc -w 5                      -> 0 바이트 (게이트웨이·ClusterIP·NodePort 전부)
#      wget                         -> HTTP/1.1 404 (Envoy 까지 도달한다)
#      nc -w 5 -i 2                 -> 172 바이트. 그런데 **opensearch 9200 에서
#                                      끝나지 않았다**(TLS 포트에 평문을 보내면
#                                      서버가 핸드셰이크를 기다린다). 안쪽
#                                      timeout 도 듣지 않아 exec 가 매달렸다.
#      { printf; sleep 3; } | nc -w 5 -> 채택. 전 대상이 3~4초에 끝나고
#                                      게이트웨이 172 · 나머지 0 으로 갈린다.
#   stdin 을 3초 열어 두면 nc 가 응답(또는 리셋)을 읽을 틈이 생기고, 그 뒤
#   EOF 로 스스로 끝난다 — -i 처럼 매달리지 않는다.
# ★ 타임아웃을 두 겹으로 둔다(안쪽 timeout 10, 바깥 timeout 25). kubectl 의
#   --request-timeout 은 exec 에 적용되지 않으므로 바깥이 필요하다.
#   **멈추지 않는 측정은 측정이 아니다.**
# ★ 한계: "거부됨" 과 "아무도 듣지 않음" 은 둘 다 0 이다. 이 시험의 질문이
#   "비인가 출발지가 말을 걸 수 있나" 이므로 그 둘을 가르지 않아도 된다.
# ★★ TCP connect 성공을 허용으로 읽지 말 것 — ztunnel 은 연결을 받아들인 뒤
#   HBONE 계층에서 거부한다(Gotcha 19·147). 실측: opensearch 9200 은
#   connect_rc=0 인데 wget 은 Connection reset 이고 응답 바이트가 0 이다.
probe_bytes() {
  local host=$1 port=$2 payload=$3 out rc=0
  out=$(timeout 25 kubectl exec "$PROBE" -n "$NAMESPACE" -- sh -c \
        "{ printf '$payload'; sleep 3; } | timeout 10 nc -w 5 $host $port 2>/dev/null | wc -c" 2>/dev/null) || rc=$?
  out=$(printf '%s' "$out" | tr -dc '0-9' | head -c 10)
  if [ "${rc:-0}" -ne 0 ] || [ -z "$out" ]; then
    echo ERR
  else
    echo "$out"
  fi
}

echo "=== 4. 장치 대조군 (이 측정이 작동하는지) ==="
GW_SVC=$(kubectl get svc -n "$NAMESPACE" \
           -l gateway.networking.k8s.io/gateway-name=ingress \
           -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
APPARATUS_OK=0
if [ -z "$GW_SVC" ]; then
  printf "%s[측정 불가]%s 인그레스 게이트웨이 Service 를 찾지 못했다 (라벨 gateway-name=ingress)\n" "$YELLOW" "$NC"
  UNMEASURED=$((UNMEASURED + 1))
else
  printf "  대조군 대상: %s:80 ... " "$GW_SVC"
  CTRL=$(probe_bytes "$GW_SVC" 80 'GET / HTTP/1.0\r\nHost: ctrl\r\n\r\n')
  if [ "$CTRL" = ERR ]; then
    printf "%s측정 실패 — 프로브가 끝나지 않았거나 exec 가 실패했다%s\n" "$YELLOW" "$NC"
    UNMEASURED=$((UNMEASURED + 1))
  elif [ "$CTRL" -gt 0 ]; then
    printf "%s응답 %s바이트 — 측정 장치 정상%s\n" "$GREEN" "$CTRL" "$NC"
    APPARATUS_OK=1
  else
    printf "%s0바이트 — 측정 장치를 믿을 수 없다%s\n" "$YELLOW" "$NC"
    echo "         (게이트웨이는 모든 출발지에 열려 있어야 한다 - Gotcha 185)"
    UNMEASURED=$((UNMEASURED + 1))
  fi
fi
echo ""

echo "=== 5. 차단 트래픽 시험 (비인가 출발지) ==="
# 형식: host:port:표시명:보낼 바이트
#   PostgreSQL 은 SSLRequest 8바이트 — 정상 서버는 S 또는 N 1바이트로 답한다.
#   HTTP(S) 포트에는 평문 요청을 보낸다 — TLS 라도 alert 바이트가 돌아오므로
#   "상대가 말을 했는가" 판정에는 충분하다.
DENIED_TESTS=(
  'postgresql-headless:5432:PostgreSQL:\000\000\000\010\004\322\026\057'
  'opensearch-headless:9200:OpenSearch:GET / HTTP/1.0\r\nHost: probe\r\n\r\n'
  'kafka-headless:9092:Kafka:\000\000\000\027\000\022\000\000\000\000\000\001\000\004prob\000'
)

if [ "$APPARATUS_OK" -ne 1 ]; then
  printf "%s[측정 불가]%s 대조군이 통과하지 못해 차단 시험을 생략한다\n" "$YELLOW" "$NC"
  UNMEASURED=$((UNMEASURED + ${#DENIED_TESTS[@]}))
else
  for test in "${DENIED_TESTS[@]}"; do
    host=${test%%:*};              rest=${test#*:}
    port=${rest%%:*};              rest=${rest#*:}
    name=${rest%%:*};              payload=${rest#*:}
    printf "  %-12s (%s:%s) ... " "$name" "$host" "$port"
    N=$(probe_bytes "$host" "$port" "$payload")
    if [ "$N" = ERR ]; then
      # ★ 여기를 "차단" 으로 적으면 거짓 안심이다. 재지 못한 것이다.
      printf "%s측정 불가 (프로브가 끝나지 않았다)%s\n" "$YELLOW" "$NC"
      UNMEASURED=$((UNMEASURED + 1))
    elif [ "$N" -eq 0 ]; then
      printf "%s차단 (정상)%s\n" "$GREEN" "$NC"
    else
      printf "%s허용 (비정상 - 응답 %s바이트)%s\n" "$RED" "$N" "$NC"
      FAILED=$((FAILED + 1))
    fi
  done
fi
echo ""

# ★ 허용 경로의 검증은 여기서 한 건만 한다(대조군이 곧 그것이다 —
#   allow-ingress-gateway). 나머지 ALLOW 정책은 **인가된 신원**이 있어야
#   재므로 이 파드로는 성립하지 않는다: ambient 에서 신원은 ServiceAccount
#   이고(Gotcha 10) 라벨 없는 임시 파드에는 정책이 기대하는 SA 가 없다.
#   옛 판은 이 파드에서 포트 열림 검사로 PostgreSQL·Kafka·OpenSearch 를 찍어
#   "ALLOWED" 로 보고했는데, 그것은 허용의 증거가 아니라 거짓 양성이었다 —
#   바로 위의 차단 시험이 같은 대상을 차단으로 판정한다.
#   ★ 복귀 조건: 각 ALLOW 정책이 기대하는 SA 로 도는 시험 파드를 만들면
#     그때 허용 경로도 잴 수 있다. 그 전까지는 재지 않았다고 적는다.
echo "=== 6. 허용 경로 (범위 밖) ==="
printf "  %s[미측정]%s 신원이 필요한 ALLOW 정책은 재지 않았다 — 머리말의 복귀 조건 참조\n" "$BLUE" "$NC"
echo "           (허용 경로 1건은 4절 대조군이 실측했다: allow-ingress-gateway)"
echo ""

echo "============================================"
echo "  NetworkPolicy 검증 결과"
echo "============================================"
printf "  실패:      %d\n" "$FAILED"
printf "  측정 불가: %d\n" "$UNMEASURED"
if [ "$FAILED" -gt 0 ]; then
  printf "  판정: %s실패%s\n" "$RED" "$NC"
  echo "============================================"
  exit 1
elif [ "$UNMEASURED" -gt 0 ]; then
  printf "  판정: %s측정 불가%s — 통과가 아니다\n" "$YELLOW" "$NC"
  echo "============================================"
  exit 2
else
  printf "  판정: %s통과%s\n" "$GREEN" "$NC"
  echo "============================================"
fi
