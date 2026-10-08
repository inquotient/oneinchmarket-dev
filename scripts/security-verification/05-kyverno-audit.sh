#!/usr/bin/env bash
# 7-5: Kyverno 정책 검증
# 실행: ./05-kyverno-audit.sh [namespace]
#
# ★★★ 2026-10-09: 이 스크립트는 넷으로 고장나 있었다.
#   ① exit 문이 아예 없어 클러스터가 꺼져 있어도 0 을 돌려줬다(거짓 통과).
#   ② 정책 이름 둘이 실제와 달랐다 — require-labels / require-probes 를 찾는데
#      실제 metadata.name 은 require-standard-labels / require-health-probes 다.
#      그래서 그 둘은 영원히 MISS 였고, exit 이 없으니 아무 영향도 없었다.
#   ③ PolicyReport 를 'for ns in dev prod' 로 봤다. 이 클러스터의 네임스페이스는
#      local 이라 둘 다 없고, 그래서 리포트를 한 번도 읽지 못했다.
#   ④ §5 가 서버 dry-run 의 응답에서 거부 문구를 찾고, 없으면
#      "NOT ENFORCED (Audit mode?)" 를 찍었다. 그것은 측정이 아니라 추측이다.
#
# ★★ ④의 정체가 이 스크립트의 설계를 바꿨다. 실측(2026-10-09): 이 클러스터의
#   6개 정책이 전부 Audit 이고, **Audit 모드의 Kyverno 는 어드미션 응답을
#   바꾸지 않는다** — root 파드와 limits 없는 파드를 서버 dry-run 해도 응답은
#   그냥 "pod/... created (server dry run)" 이고 경고 한 줄도 없다. 결과는
#   PolicyReport 로만 간다.
#   즉 **dry-run 으로 Audit 정책을 검증할 수 없다.** Audit 의 측정 지점은
#   §2 의 PolicyReport 이고, dry-run 은 Enforce 일 때만 뜻이 있다.
#
# 판정은 셋이다: 0 통과 · 1 실패 · 2 측정 불가.

set -euo pipefail

FAILED=0
WARNED=0
UNMEASURED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NAMESPACE="${1:-}"
if [ -z "$NAMESPACE" ]; then
  NAMESPACE="$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || true)"
  [ -n "$NAMESPACE" ] || NAMESPACE=default
fi

POLICIES=(
  "disallow-root-user"
  "require-resource-limits"
  "disallow-latest-tag"
  "disallow-privilege-escalation"
  "require-standard-labels"
  "require-health-probes"
)

echo "============================================"
echo "  Kyverno 정책 검증 (ns=${NAMESPACE})"
echo "============================================"
echo ""

echo "=== 0. 측정 장치 확인 ==="
if ! kubectl version --request-timeout=10s >/dev/null 2>&1; then
  printf "${BLUE}[측정 불가]${NC} 클러스터에 닿지 못한다\n"
  exit 2
fi
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  printf "${BLUE}[측정 불가]${NC} 네임스페이스 %s 가 없다 — 대상을 잘못 보고 있다\n" "$NAMESPACE"
  exit 2
fi
if ! kubectl get clusterpolicy >/dev/null 2>&1; then
  printf "${BLUE}[측정 불가]${NC} ClusterPolicy 를 읽지 못한다 — Kyverno 가 없거나 CRD 가 없다\n"
  exit 2
fi
printf "${GREEN}[OK]${NC}   클러스터·네임스페이스 %s·ClusterPolicy 를 읽을 수 있다\n" "$NAMESPACE"
echo ""

echo "=== 1. ClusterPolicy 존재와 실효 action ==="
# ★ action 을 두 자리에서 읽는다. Kyverno 1.13 은 spec.validationFailureAction
#   이지만 **1.14 가 그 필드를 없애고** rules[].validate.failureAction 으로
#   옮겼다. 지금은 v1.13.2 로 핀되어 있다(local/install-operators.sh) —
#   올리는 날 한쪽만 읽는 코드는 조용히 빈 값을 보게 된다.
declare -A ACTION_OF
for policy in "${POLICIES[@]}"; do
  if ACT=$(kubectl get clusterpolicy "$policy" -o go-template='{{if .spec.validationFailureAction}}{{.spec.validationFailureAction}}{{else}}{{range .spec.rules}}{{if .validate}}{{if .validate.failureAction}}{{.validate.failureAction}}{{end}}{{end}}{{end}}{{end}}' 2>/dev/null); then
    if [ -z "$ACT" ]; then
      ACT=Audit
      printf "${YELLOW}[WARN]${NC} %-32s action 이 두 자리 어디에도 없다 — Kyverno 기본값(Audit)으로 읽는다\n" "$policy"
      WARNED=$((WARNED + 1))
    else
      printf "${GREEN}[OK]${NC}   %-32s action: %s\n" "$policy" "$ACT"
    fi
    ACTION_OF["$policy"]="$ACT"
  else
    printf "${RED}[FAIL]${NC} %-32s 없다 — 이 정책은 아무것도 막지 않는다\n" "$policy"
    FAILED=$((FAILED + 1))
    ACTION_OF["$policy"]=""
  fi
done
echo ""
echo "=== 2. PolicyReport — Audit 정책의 실제 측정 지점 ==="
# ★★ 여기가 핵심이다. Audit 모드에서 Kyverno 가 결과를 남기는 곳은 여기뿐이다.
#   옛 판은 dev·prod 를 보아 아무것도 읽지 못했다.
NREP=$(kubectl get policyreport -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${NREP:-0}" = 0 ]; then
  printf "${BLUE}[측정 불가]${NC} %s 에 PolicyReport 가 0개다 — reports-controller 가 도는지 볼 것\n" "$NAMESPACE"
  UNMEASURED=$((UNMEASURED + 1))
else
  SUM=$(kubectl get policyreport -n "$NAMESPACE" -o go-template='{{range .items}}{{.summary.pass}} {{.summary.fail}} {{.summary.warn}} {{.summary.error}} {{.summary.skip}}{{"\n"}}{{end}}' 2>/dev/null \
        | awk '{p+=$1;f+=$2;w+=$3;e+=$4;s+=$5} END{printf "%d %d %d %d %d", p,f,w,e,s}')
  set -- $SUM
  printf "  리포트 %s개 — pass=%s fail=%s warn=%s error=%s skip=%s\n" "$NREP" "$1" "$2" "$3" "$4" "$5"

  # ★★★ 장치 대조군: 우리 정책이 리포트에 **나타나는가**. 나타나지 않으면
  #   정책은 있고 웹훅이 평가하지 않는 것이다 — 이 레포가 반복해서 만난
  #   "설정은 있고, 아무도 읽지 않고, 오류는 없다"(Gotcha 33·84·141·155)다.
  #   fail 이 0 인 것과 **평가되지 않은 것**은 완전히 다르다.
  MISSING=0
  for policy in "${POLICIES[@]}"; do
    [ -n "${ACTION_OF[$policy]}" ] || continue
    N=$(kubectl get policyreport -n "$NAMESPACE" -o json 2>/dev/null \
        | jq -r --arg p "$policy" '[.items[].results[]? | select(.policy==$p)] | length' 2>/dev/null || echo "")
    if [ -z "$N" ] || [ "$N" = 0 ]; then
      printf "${RED}[FAIL]${NC} %-32s 리포트에 결과가 0건 — 평가되지 않고 있다\n" "$policy"
      FAILED=$((FAILED + 1))
      MISSING=$((MISSING + 1))
    else
      NF_=$(kubectl get policyreport -n "$NAMESPACE" -o json 2>/dev/null \
            | jq -r --arg p "$policy" '[.items[].results[]? | select(.policy==$p and .result=="fail")] | length' 2>/dev/null || echo 0)
      # ★ fail 을 실패로 세지 않는다. local 은 전부 Audit 이고 위반 수백 건이
      #   알려진 상태다 — 빨간불이 상수가 되면 사람이 배경으로 읽는다
      #   (Gotcha 73·90). 수치로 남긴다.
      printf "${GREEN}[OK]${NC}   %-32s 평가됨 (결과 %s건 · 그중 fail %s건)\n" "$policy" "$N" "$NF_"
      if [ "${NF_:-0}" -gt 0 ]; then WARNED=$((WARNED + 1)); fi
    fi
  done
  if [ "$MISSING" = 0 ]; then
    printf "${GREEN}[OK]${NC}   대조군 통과 — 6개 정책 전부 리포트에 나타난다(웹훅이 평가하고 있다)\n"
  fi
fi
echo ""

echo "=== 3. ClusterPolicyReport (참고) ==="
NCPR=$(kubectl get clusterpolicyreport --no-headers 2>/dev/null | wc -l | tr -d ' ')
printf "  %s개\n" "${NCPR:-0}"
if [ "${NCPR:-0}" != 0 ]; then
  kubectl get clusterpolicyreport -o go-template='{{range .items}}    {{.metadata.name}}{{"\t"}}pass={{.summary.pass}} fail={{.summary.fail}} warn={{.summary.warn}}{{"\n"}}{{end}}' 2>/dev/null || true
else
  echo "    (클러스터 범위 리소스에 걸리는 정책이 없으면 0개가 정상이다 — 실패로 세지 않는다)"
fi
echo ""

echo "=== 4. PolicyViolation 이벤트 (참고, 최근 10건) ==="
# ★ 이벤트는 소음이 될 수 있다 — 누수된 ConfigMap 68개가 끝없이 위반을 찍어
#   이벤트 로그를 통째로 덮은 적이 있다(Gotcha 62). 참고로만 본다.
kubectl get events -n "$NAMESPACE" --field-selector reason=PolicyViolation \
  --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || echo "  (없음)"
echo ""
echo "=== 5. Enforce 정책의 실제 차단 확인 ==="
# ★★★ 옛 판은 Audit 정책에 dry-run 을 걸고 거부가 없으면 "NOT ENFORCED
#   (Audit mode?)" 를 찍었다. 그것은 측정이 아니다 — 실측으로 Audit 모드는
#   어드미션 응답을 **바꾸지 않으므로** 거부도 경고도 나올 수 없다.
#   그래서 여기서는 **Enforce 인 정책만** 시험한다. Audit 은 §2 가 측정했다.
# ★ Enforce 인데 막지 못하면 그것은 진짜 실패다 — 정책이 Enforce 라고 말하면서
#   아무것도 막지 않는 것이니까.
run_block_test() {
  pol="$1"; name="$2"; ovr="$3"
  act="${ACTION_OF[$pol]:-}"
  if [ -z "$act" ]; then
    printf "  %-32s ${BLUE}건너뜀${NC} (정책이 없다 — §1 에서 이미 실패로 셌다)\n" "$pol"
    return
  fi
  if [ "$act" != Enforce ]; then
    printf "  %-32s ${BLUE}이 방법으로는 측정 불가${NC} (action=%s — dry-run 은 응답을 받지 못한다. §2 가 측정했다)\n" "$pol" "$act"
    return
  fi
  OUT=$(kubectl -n "$NAMESPACE" run "$name" --image=docker.io/library/nginx:1.29.3 \
          --restart=Never --overrides="$ovr" --dry-run=server 2>&1 || true)
  if printf '%s' "$OUT" | grep -qiE 'denied|blocked|violat|admission webhook'; then
    printf "  %-32s ${GREEN}차단됨${NC} (Enforce 와 일치)\n" "$pol"
  else
    printf "  %-32s ${RED}차단되지 않았다${NC} — Enforce 인데 통과시켰다\n" "$pol"
    FAILED=$((FAILED + 1))
  fi
}

run_block_test "disallow-root-user" "sv-dry-root" \
  '{"spec":{"securityContext":{"runAsUser":0}}}'
run_block_test "require-resource-limits" "sv-dry-nolimit" \
  '{"spec":{"containers":[{"name":"sv-dry-nolimit","image":"docker.io/library/nginx:1.29.3"}]}}'
run_block_test "disallow-privilege-escalation" "sv-dry-privesc" \
  '{"spec":{"containers":[{"name":"sv-dry-privesc","image":"docker.io/library/nginx:1.29.3","securityContext":{"allowPrivilegeEscalation":true}}]}}'
# ★ --dry-run=server 는 아무것도 남기지 않는다(실측으로 확인했다) — 그래서
#   정리 단계가 없다. 그래도 이름에 sv-dry- 접두를 둔 것은, 혹시 남으면
#   무엇이 남겼는지 알 수 있게 하기 위해서다.
echo ""

echo "============================================"
echo "  Kyverno 검증 결과"
echo "============================================"
printf "  실패: %d\n" "$FAILED"
printf "  경고: %d (위반 수치 — 실패로 세지 않는다)\n" "$WARNED"
printf "  측정 불가: %d\n" "$UNMEASURED"
echo "============================================"
echo "  ★ 이 표의 통과를 '정책이 막고 있다' 로 읽지 말 것 — local 은 6개가"
echo "    전부 Audit 이므로 **아무것도 막지 않는다.** 측정한 것은 '정책이"
echo "    존재하고 평가되고 있다' 까지다. 차단은 prod 의 Enforce 에서만 성립한다."
echo "============================================"
if [ "$FAILED" -gt 0 ]; then
  printf "  판정: ${RED}실패${NC}\n"
  exit 1
fi
if [ "$UNMEASURED" -gt 0 ]; then
  printf "  판정: ${BLUE}측정 불가${NC} — 통과로 접지 않는다\n"
  exit 2
fi
printf "  판정: ${GREEN}통과${NC} (경고 %d건)\n" "$WARNED"
