#!/usr/bin/env bash
# 7-9: RBAC 최소 권한 감사
#
# 사전 조건: kubectl (클러스터 연결 상태)
# 실행: ./09-rbac-audit.sh [namespace]
#
# 종료 코드: 0 통과 · 1 실패 · 2 측정 불가
#
# ★★★ 2026-10-07 실측으로 옛 판의 결함 셋을 고쳤다. 셋 다 "오류 없이
#   틀린 답" 이라 아무도 알려 주지 않았다:
#
#   ① wildcard 검사가 **항상 WARN** 이었다.
#        kubectl ... -o json | grep -l '"*"'
#      grep -l 은 매칭된 **파일 이름**을 찍는데 stdin 이면 "(standard input)"
#      을 찍는다. 즉 결과 변수가 절대로 비지 않아 매번 "Wildcard 권한 발견"
#      이었다. 게다가 BRE 에서 "*" 는 따옴표 0회 이상 + 따옴표라 **아무 따옴표
#      한 개**에 매칭된다 — 실측으로 wildcard 가 있는 JSON 과 없는 JSON 이
#      똑같이 1 로 세어졌다. 올바른 것은 고정 문자열 매칭이다.
#
#   ② secret verb 검사가 JSON 을 grep -A5 로 읽었다.
#      필드 순서를 가정한 것이라 resources 와 verbs 가 5줄 안에 함께 없으면
#      **조용히 빗나간다.** jsonpath 로 규칙 단위로 뽑아 비교한다.
#
#   ③ automount 계수가 **스크립트를 죽였다.**
#        V=$(kubectl ... | grep -c '...' || echo "0")
#      grep -c 는 0건일 때 "0" 을 찍고 **종료 코드 1** 을 낸다. 그러면
#      || echo "0" 이 추가로 실행되어 값이 두 줄이 되고,
#      [ "$V" -gt 0 ] 이 "integer expression expected" 로 rc=2 를 돌려준다.
#      set -e 가 거기서 스크립트를 끝내므로 **요약에 도달한 적이 없다.**
#      실측으로 rc=2 와 그 오류 문구를 재현했다.
#
# ★★ 그리고 판정 범위를 **이 프로젝트가 소유한 롤**로 좁혔다. 클러스터에는
#   cluster-admin 처럼 wildcard 를 가진 내장 ClusterRole 이 원래 많다 —
#   그것까지 세면 빨간불이 상수가 되어 사람이 배경으로 읽는다(Gotcha 73·90).
#   달성할 수 없는 게이트는 없는 게이트보다 나쁘다.
#
# ★ 판정은 둘이 아니라 셋이다 — 통과 / 실패 / **측정 불가**(07 과 같다).

set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

NAMESPACE="${1:-dev}"
PROJECT_LABEL="app.kubernetes.io/part-of=oneinchmarket"

FAILED=0
WARNED=0
UNMEASURED=0

echo "============================================"
echo "  RBAC 최소 권한 감사 (namespace: $NAMESPACE)"
echo "============================================"
echo ""

# API 에 닿는지 먼저 본다. "읽을 수 없다" 를 "없다" 로 적지 않기 위해서다.
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  printf "%s[측정 불가]%s 네임스페이스 %s 를 읽을 수 없다 — API 에 닿지 못했다\n" "$YELLOW" "$NC" "$NAMESPACE"
  echo ""
  echo "============================================"
  printf "  판정: %s측정 불가%s — 감사하지 못했다\n" "$YELLOW" "$NC"
  echo "============================================"
  exit 2
fi

# ───────────────────────────────────────────────
echo "=== 1. ServiceAccount 목록 ==="
SA_COUNT=$(kubectl get sa -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
printf "  ServiceAccount %s개\n" "$SA_COUNT"
kubectl get sa -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{printf "    - %s\n", $1}' | head -40
if [ "$SA_COUNT" -gt 40 ]; then printf "    ... (상위 40개만 표시)\n"; fi
echo ""

# ───────────────────────────────────────────────
# 규칙을 한 줄에 하나씩 뽑는다. 형식: <이름> <TAB> verbs <TAB> resources
#
# ★★★ 2026-10-09: 옛 판은 jsonpath 였고 **규칙이 둘 이상인 롤에서 어긋났다.**
#   이름을 **규칙 루프 밖에서** 찍었으므로 두 번째 규칙부터는 이름 열이 비고
#   필드가 한 칸씩 밀린다. 그리고 어긋나는 데서 그치지 않았다 — 실측에서
#   falco 의 3번째 규칙(nonResourceURLs)은 resources 가 없어 필드가 **둘**이라
#   awk -F'\t' 의 NF>=3 에 **조용히 걸러졌다.** 즉 보지 않은 규칙이 있었다.
# ★ 이름을 안쪽으로 옮기는 것으로는 고칠 수 없다 — kubectl jsonpath 에는
#   부모를 가리키는 연산자가 없어 규칙 루프 안에서 롤 이름을 읽을 길이 없다.
#   go-template 은 바깥에서 변수를 묶을 수 있다.
# ★★ 그런데 배열을 그대로 찍으면 [get list] 가 되어 **소비처의 "*" ·
#   "secrets" 매칭이 깨진다.** 그래서 따옴표까지 직접 조립해 jsonpath 와 같은
#   모양(["get","list"])을 유지한다 — 소비처를 손대지 않아도 된다.
# ★ 실측(local, 2026-10-09): 19줄 전부 NF>=3 · 이름 누락 0 · 빈 resources 는
#   [] 로 찍히고 wildcard 2건을 그대로 검출한다.
RULE_TMPL='{{range .items}}{{$n := .metadata.name}}{{range .rules}}{{$n}}{{"\t"}}[{{range $i, $v := .verbs}}{{if $i}},{{end}}"{{$v}}"{{end}}]{{"\t"}}[{{range $i, $r := .resources}}{{if $i}},{{end}}"{{$r}}"{{end}}]{{"\n"}}{{end}}{{end}}'

echo "=== 2. 네임스페이스 Role 규칙 ==="
NS_RULES=$(kubectl get roles -n "$NAMESPACE" -o go-template="$RULE_TMPL" 2>/dev/null || echo "")
if [ -z "$NS_RULES" ]; then
  printf "  %s(Role 이 없다)%s\n" "$BLUE" "$NC"
else
  printf "%s\n" "$NS_RULES" | awk -F'\t' 'NF>=3 {printf "    %-28s verbs=%-34s resources=%s\n", $1, $2, $3}'
fi
echo ""

echo "=== 3. 프로젝트 ClusterRole 규칙 ($PROJECT_LABEL) ==="
CR_RULES=$(kubectl get clusterroles -l "$PROJECT_LABEL" -o go-template="$RULE_TMPL" 2>/dev/null || echo "")
if [ -z "$CR_RULES" ]; then
  printf "  %s(라벨이 붙은 ClusterRole 이 없다)%s\n" "$BLUE" "$NC"
  echo "    ★ 라벨이 없으면 이 감사의 범위에서 빠진다 — 새 ClusterRole 에는"
  echo "      app.kubernetes.io/part-of: oneinchmarket 을 붙일 것"
else
  printf "%s\n" "$CR_RULES" | awk -F'\t' 'NF>=3 {printf "    %-28s verbs=%-34s resources=%s\n", $1, $2, $3}'
fi
echo ""

ALL_RULES=$(printf "%s\n%s\n" "$NS_RULES" "$CR_RULES")

# ───────────────────────────────────────────────
echo "=== 4. 과도한 권한 검출 ==="

# 4-1. wildcard. 고정 문자열 "*" 를 찾는다 — 정규식으로 쓰면 아무 따옴표에나 걸린다.
echo "--- 4-1. Wildcard(*) 권한 ---"
WILD=$(printf "%s\n" "$ALL_RULES" | grep -F '"*"' || true)
if [ -z "$WILD" ]; then
  printf "%s[OK]%s   프로젝트 소유 롤에 wildcard 권한 없음\n" "$GREEN" "$NC"
else
  printf "%s[FAIL]%s wildcard 권한을 가진 규칙:\n" "$RED" "$NC"
  printf "%s\n" "$WILD" | awk -F'\t' '{printf "         %-28s verbs=%s resources=%s\n", $1, $2, $3}'
  FAILED=$((FAILED + 1))
fi
echo ""

# 4-2. Secret 에 대한 쓰기 권한. 규칙 단위로 보고 verbs 와 resources 를 함께 본다.
echo "--- 4-2. Secret 접근 권한 ---"
SEC_RULES=$(printf "%s\n" "$ALL_RULES" | awk -F'\t' 'NF>=3 && $3 ~ /"secrets"/' || true)
if [ -z "$SEC_RULES" ]; then
  printf "%s[OK]%s   secrets 를 참조하는 규칙 없음\n" "$GREEN" "$NC"
else
  while IFS=$'\t' read -r rname rverbs rres; do
    [ -n "${rname:-}" ] || continue
    case "$rverbs" in
      *'"*"'*)
        printf "%s[FAIL]%s %-26s secrets 에 wildcard verb: %s\n" "$RED" "$NC" "$rname" "$rverbs"
        FAILED=$((FAILED + 1)) ;;
      *'"delete"'*|*'"create"'*|*'"deletecollection"'*)
        printf "%s[WARN]%s %-26s secrets 에 쓰기 verb: %s\n" "$YELLOW" "$NC" "$rname" "$rverbs"
        WARNED=$((WARNED + 1)) ;;
      *)
        printf "%s[OK]%s   %-26s %s\n" "$GREEN" "$NC" "$rname" "$rverbs" ;;
    esac
  done <<< "$SEC_RULES"
  echo "         (권장: 로테이션은 get+patch 로 충분하다. create/delete 는 사유를 적을 것)"
fi
echo ""

# 4-3. default ServiceAccount 로 도는 파드. 이 레포는 0 을 목표로 한다(Gotcha 19).
echo "--- 4-3. default ServiceAccount 사용 Pod ---"
DEFAULT_SA_PODS=$(kubectl get pods -n "$NAMESPACE" \
  -o jsonpath='{range .items[?(@.spec.serviceAccountName=="default")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")
DEFAULT_SA_PODS=$(printf "%s\n" "$DEFAULT_SA_PODS" | sed '/^$/d')
if [ -z "$DEFAULT_SA_PODS" ]; then
  printf "%s[OK]%s   모든 Pod 가 전용 ServiceAccount 를 쓴다\n" "$GREEN" "$NC"
else
  CNT=$(printf "%s\n" "$DEFAULT_SA_PODS" | wc -l | tr -d ' ')
  printf "%s[FAIL]%s default SA 로 도는 Pod %s개:\n" "$RED" "$NC" "$CNT"
  printf "%s\n" "$DEFAULT_SA_PODS" | awk '{printf "         - %s\n", $1}'
  echo "         (ambient 에서 SA 는 곧 신원이다 — 공유하면 정책을 쓸 수 없다, Gotcha 10)"
  FAILED=$((FAILED + 1))
fi
echo ""

# ───────────────────────────────────────────────
# ★ 질문을 바르게 세울 것: automountServiceAccountToken 의 기본값은 true 이고
#   대부분의 파드 스펙에는 **그 필드가 아예 없다.** 그러므로 "true 인 것을
#   세는" 것은 거의 언제나 0 이 나오고 그 0 은 좋은 뜻이 아니다.
#   세야 하는 것은 **명시적으로 끈 파드의 수**다(SEC-202 의 목표).
echo "=== 5. SA Token 자동 마운트 (SEC-202) ==="
TOTAL_PODS=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
OPTED_OUT=$(kubectl get pods -n "$NAMESPACE" \
  -o jsonpath='{range .items[?(@.spec.automountServiceAccountToken==false)]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | sed '/^$/d' | wc -l | tr -d ' ')
OPTED_OUT=${OPTED_OUT:-0}
printf "  Pod 총 수:            %s\n" "$TOTAL_PODS"
printf "  automount 를 끈 Pod:  %s\n" "$OPTED_OUT"
if [ "$TOTAL_PODS" -gt 0 ]; then
  printf "  (나머지 %s개는 기본값 true 로 토큰을 마운트한다)\n" "$((TOTAL_PODS - OPTED_OUT))"
fi
printf "  %s[목표]%s SEC-202 는 아직 달성 상태가 아니다 — 실패로 세지 않고 수치만 남긴다\n" "$BLUE" "$NC"
echo ""

# ───────────────────────────────────────────────
echo "============================================"
echo "  RBAC 감사 결과"
echo "============================================"
printf "  실패:      %d\n" "$FAILED"
printf "  경고:      %d\n" "$WARNED"
printf "  측정 불가: %d\n" "$UNMEASURED"
echo ""
echo "  권장사항:"
echo "   1. Secret 접근은 get·patch 까지. create·delete 는 사유를 매니페스트에 적을 것"
echo "   2. 모든 워크로드에 전용 ServiceAccount (ambient 에서 SA 는 신원이다)"
echo "   3. 프로젝트 소유 롤에 wildcard(*) 금지"
echo "   4. 새 ClusterRole 에 app.kubernetes.io/part-of: oneinchmarket 라벨 (없으면 감사 범위 밖)"
echo "============================================"
if [ "$FAILED" -gt 0 ]; then
  printf "  판정: %s실패%s\n" "$RED" "$NC"
  exit 1
elif [ "$UNMEASURED" -gt 0 ]; then
  printf "  판정: %s측정 불가%s — 통과가 아니다\n" "$YELLOW" "$NC"
  exit 2
else
  printf "  판정: %s통과%s (경고 %d건)\n" "$GREEN" "$NC" "$WARNED"
fi
