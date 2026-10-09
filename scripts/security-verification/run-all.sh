#!/usr/bin/env bash
# OneinchMarket v2 - 보안 검증 전체 실행
#
# 실행: ./run-all.sh [namespace]
# 종료 코드: 0 신규 실패 없음 · 1 실패 있음 · 2 측정 불가만 있음
#
# 검증 항목:
#   7-1: kube-bench (CIS Benchmark)           — k3s 전용 벤치마크로 판정한다
#   7-2: kubesec (매니페스트 보안 점수)
#   7-3: Trivy (이미지 CVE + 매니페스트 스캔)
#   7-4: 로테이션 dry-run
#   7-5: Kyverno Audit (정책 위반 리포트)
#   7-6: Falco 규칙 검증                      — 검증된 자극으로 판정한다
#   7-7: NetworkPolicy (허용/차단 트래픽)
#   7-8: age 키 백업 검증                     — 기존 결함(SOPS 미작동)
#   7-9: RBAC 최소 권한 감사
#
# ★★★ 2026-10-07 에 이 러너가 **무엇이 실패해도 "검증 완료" 를 찍고
#   종료 코드 0 을 돌려주는** 구조였음이 드러났다. 원인이 둘이다:
#     ① 모든 호출이 "2>&1 | tee ... || true" 로 끝나 종료 코드를 버렸다.
#     ② 개별 스크립트 넷(03·04·05·08)에 exit 문이 아예 없어 **구조적으로
#        실패할 수 없었다.** 08 은 CLAUDE.md 가 "오늘 돌리면 13건 FAIL" 이라
#        적어 둔 것인데도 0 을 돌려주고 있었다.
#   그 결과 docs/PRD.md 의 성공 기준 S-3("run-all.sh 전 항목 PASS")이
#   **반증 불가능**했다. 통과를 선언할 수 없는 게이트보다, 실패를 선언할
#   수 없는 게이트가 더 나쁘다 — 후자는 없는 것이 아니라 거짓 증명이다.
#
# ★★ 그래서 판정을 셋으로 나눈다 — 통과 / 실패 / **측정 불가**.
#   측정 불가를 통과로 접지 않는 것이 이 러너의 유일한 규칙이다.
#   그리고 **이미 알고 있는 결함**(KNOWN_FAILING)은 따로 센다: 매번 같은
#   발견으로 빨간불이 상수가 되면 사람이 배경으로 읽고 그때는 새 구멍도
#   함께 묻힌다(Gotcha 73·90 과 같은 구조).
#
# ★ 집계 구조는 scripts/ha-verification/run-all.sh 의 것을 따랐다 —
#   레포 안에 이미 올바른 선례가 있었다.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="${1:-dev}"
REPORT_DIR="/tmp/oneinchmarket-security-report-$(date +%Y%m%d-%H%M%S)"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
NC=$'\033[0m'

mkdir -p "$REPORT_DIR"
SUMMARY="$REPORT_DIR/summary.txt"
: > "$SUMMARY"

# ★ 이미 알고 있는 결함의 번호를 공백으로 나누어 적는다. 적을 때는 **사유와
#   복귀 조건을 함께** 적을 것 — 목록만 있고 사유가 없으면 다음 사람이
#   판단할 근거가 없어 그냥 지운다. 그리고 사유가 사라진 항목을 남겨 두지
#   말 것: 실측해 보지 않은 회피책이 더 나쁜 결함을 데려온다(Gotcha 131).
#
#   ★★ 지금은 비어 있다 — 2026-10-07 에 실측해서 비웠다.
#     여기에 "7-8" 을 적어 두려 했으나(CLAUDE.md 가 "오늘 돌리면 13건 FAIL"
#     이라 적고 있었다) **실제로 돌려 보니 실패 0 · 경고 13** 이었다.
#     7-8 이 보고하는 것은 전부 자리표시자(.enc.yaml 11개 중 11개가 PH)이고
#     그것은 SOPS 를 쓰지 않기로 미뤄 둔 상태의 당연한 결과다(ADR-024 가
#     Vault/OpenBao 전환을 검토 중이며, 채택되면 이 검사 자체가 사라진다).
#     ★ 복귀 조건: SOPS 를 실제로 쓰기로 정하고 키를 만들면, 그때는 자리
#       표시자가 경고가 아니라 실패다 — 08 의 PH 분류를 FAIL 로 올리고
#       전환 기간에만 여기에 "7-8" 을 적을 것.
KNOWN_FAILING=""

# 참고 항목 — 수치 판정을 하지 않고 출력만 남긴다.
#   ★★★ 2026-10-09 에 비웠다. 그때까지 여기에 "7-1 7-6" 이 있었고, 그 둘은
#   매니페스트를 apply 하기만 하는 형태라 **판정이 없었다**(run_yaml 이
#   "로그는 사람이 읽을 것" 을 찍었다). 그래서 스위트 아홉 중 둘이 늘
#   "참고" 였다 — 그것은 "정하지 않는다고 적는 것" 이라기보다 **재지 않는
#   것**이었다. 같은 날 둘을 스크립트로 바꿔 스스로 판정하게 했다:
#     7-1  k3s 전용 벤치마크(k3s-cis-1.9) + 읽기 전용 SA. FAIL 을 발견과
#          측정 불가로 **가른다** — 첫 실측의 fail 28 은 실재 발견 0 이었다.
#     7-6  실측으로 고른 자극 넷. 예전 시험 셋 중 둘은 어떤 규칙도 건드릴 수
#          없었고(tty 없는 쉘 · read 로 open_write 규칙), 하나는 SA 토큰을
#          로그에 찍었다.
#   ★ 다시 적을 때는 **왜 판정할 수 없는지**를 함께 적을 것. 비어 있는 것이
#     기본값이다 — 참고는 측정의 면제가 아니다.
INFO_ONLY=""

PASS=0; FAIL=0; UNMEASURED=0; KNOWN=0; INFO=0

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   OneinchMarket v2 - 보안 검증 리포트            ║"
echo "║   Namespace: ${NAMESPACE}"
echo "║   Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "리포트 저장 경로: $REPORT_DIR"
echo ""

in_list() {
  local needle="$1" hay="$2" w
  for w in $hay; do [ "$w" = "$needle" ] && return 0; done
  return 1
}

record() {   # num name rc verdict
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$SUMMARY"
}

classify() { # num name rc
  local num=$1 name=$2 rc=$3 verdict
  if in_list "$num" "$INFO_ONLY"; then
    verdict="참고"; INFO=$((INFO + 1))
    printf "  %s=> %s: 참고 (판정하지 않는다, rc=%s)%s\n" "$BLUE" "$num" "$rc" "$NC"
  elif [ "$rc" -eq 0 ]; then
    verdict="통과"; PASS=$((PASS + 1))
    printf "  %s=> %s: 통과%s\n" "$GREEN" "$num" "$NC"
  elif in_list "$num" "$KNOWN_FAILING"; then
    verdict="기존 결함"; KNOWN=$((KNOWN + 1))
    printf "  %s=> %s: 기존 결함 (rc=%s) — 머리말의 사유·복귀 조건 참조%s\n" "$YELLOW" "$num" "$rc" "$NC"
  elif [ "$rc" -eq 2 ]; then
    verdict="측정 불가"; UNMEASURED=$((UNMEASURED + 1))
    printf "  %s=> %s: 측정 불가 (rc=2) — 통과가 아니다%s\n" "$YELLOW" "$num" "$NC"
  else
    verdict="실패"; FAIL=$((FAIL + 1))
    printf "  %s=> %s: 실패 (rc=%s)%s\n" "$RED" "$num" "$rc" "$NC"
  fi
  record "$num" "$name" "$rc" "$verdict"
}

run_sh() {   # num name script
  local num=$1 name=$2 script=$3 rc
  echo ""
  printf "%s━━━ %s: %s ━━━%s\n" "$BOLD" "$num" "$name" "$NC"
  echo ""
  if [ ! -f "$SCRIPT_DIR/$script" ]; then
    echo "스크립트 없음: $script" | tee "$REPORT_DIR/${num}.txt"
    classify "$num" "$name" 127
    return
  fi
  # ★ 종료 코드를 tee 에게 빼앗기지 않는다 — PIPESTATUS 로 첫 항목을 읽는다.
  bash "$SCRIPT_DIR/$script" "$NAMESPACE" 2>&1 | tee "$REPORT_DIR/${num}.txt"
  rc=${PIPESTATUS[0]}
  classify "$num" "$name" "$rc"
}

# ★ run_yaml() 은 2026-10-09 에 지웠다 — 호출자가 0 개가 됐다.
#   그것은 매니페스트를 apply 하고 "결과는 Job 로그에 남는다 — kubectl logs 로
#   확인할 것" 을 찍은 뒤 **무조건 통과(rc=0)로 분류**했다. 즉 "적용됐다" 를
#   "검증됐다" 로 적는 함수였다. 되살리지 말 것: 결과를 읽지 않는 검증은
#   검증이 아니다(Gotcha 191). 7-1·7-6 은 이제 스크립트로 스스로 판정한다.

# ───────────────────────────────────────────────
echo "═══════════════════════════════════════════"
echo "  Part A: 로컬 검증 (클러스터 불필요)"
echo "═══════════════════════════════════════════"

run_sh "7-2" "kubesec 매니페스트 보안 점수" "02-kubesec-scan.sh"
run_sh "7-3" "Trivy 이미지/매니페스트 스캔"  "03-trivy-scan.sh"
run_sh "7-8" "age 키 백업 검증"              "08-age-key-backup.sh"

echo ""
echo "═══════════════════════════════════════════"
echo "  Part B: 클러스터 검증 (kubectl 필요)"
echo "═══════════════════════════════════════════"

if kubectl cluster-info > /dev/null 2>&1; then
  run_sh   "7-1" "kube-bench CIS Benchmark"  "01-kube-bench.sh"
  run_sh   "7-4" "로테이션 Dry-Run"          "04-rotation-dryrun.sh"
  run_sh   "7-5" "Kyverno Audit 리포트"      "05-kyverno-audit.sh"
  run_sh   "7-6" "Falco 규칙 검증"            "06-falco-test.sh"
  run_sh   "7-7" "NetworkPolicy 검증"        "07-netpol-test.sh"
  run_sh   "7-9" "RBAC 최소 권한 감사"        "09-rbac-audit.sh"
else
  echo ""
  printf "%s[측정 불가]%s 클러스터에 닿지 못했다 — Part B 를 돌리지 못했다.\n" "$YELLOW" "$NC"
  echo "  ★ 이것은 통과가 아니다. 클러스터를 띄운 뒤 다시 돌릴 것."
  for pair in "7-1:kube-bench" "7-4:로테이션 Dry-Run" "7-5:Kyverno Audit" \
              "7-6:Falco 규칙 검증" "7-7:NetworkPolicy 검증" "7-9:RBAC 감사"; do
    num=${pair%%:*}; nm=${pair#*:}
    if in_list "$num" "$INFO_ONLY"; then
      INFO=$((INFO + 1)); record "$num" "$nm" "-" "참고(미실행)"
    else
      UNMEASURED=$((UNMEASURED + 1)); record "$num" "$nm" "-" "측정 불가(미실행)"
    fi
  done
fi

# ───────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   검증 결과                                      ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
printf "%-8s %-30s %-5s %s\n" "번호" "항목" "rc" "판정"
echo "----------------------------------------------------------------------"
while IFS=$'\t' read -r n nm rc v; do
  [ -n "${n:-}" ] || continue
  printf "%-8s %-30s %-5s %s\n" "$n" "$nm" "$rc" "$v"
done < "$SUMMARY"
echo "----------------------------------------------------------------------"
printf "  통과 %s%d%s · 실패 %s%d%s · 측정 불가 %s%d%s · 기존 결함 %s%d%s · 참고 %s%d%s\n" \
  "$GREEN" "$PASS" "$NC" "$RED" "$FAIL" "$NC" "$YELLOW" "$UNMEASURED" "$NC" \
  "$YELLOW" "$KNOWN" "$NC" "$BLUE" "$INFO" "$NC"
echo ""
printf "%s주의%s — 통과 건수는 '보안이 된다' 는 뜻이 아니다.\n" "$BOLD" "$NC"
echo "  · 7-1·7-6 은 2026-10-09 까지 '참고' 였다 — 매니페스트를 apply 하기만"
echo "    했고 결과를 아무도 읽지 않았다. 이제 스스로 판정한다. 7-1 은 FAIL 을"
echo "    발견과 측정 불가로 가르고(k3s 는 인자를 품어 23건이 잴 수 없다),"
echo "    7-6 은 경보가 오지 않은 노드를 지목한다"
echo "  · 03·04·05 에 2026-10-09 에 자체 판정이 들어왔다 — 이제 발견을 통과로"
echo "    접지 않는다. 대신 각 스크립트가 **재지 못한 것**을 스스로 적는다:"
echo "    05 는 local 이 전부 Audit 이라 '차단' 을 잴 수 없다고 말하고,"
echo "    03 은 스캔에 실패한 이미지를 '깨끗' 과 다른 칸에 넣는다"
echo "  · 측정 불가는 통과가 아니다"
echo ""
echo "  리포트: $REPORT_DIR"
echo "  요약:   $SUMMARY"
echo ""

if [ "$FAIL" -gt 0 ]; then
  printf "%s판정: 실패%s\n" "$RED" "$NC"
  exit 1
elif [ "$UNMEASURED" -gt 0 ]; then
  printf "%s판정: 측정 불가%s — 통과가 아니다\n" "$YELLOW" "$NC"
  exit 2
else
  printf "%s판정: 신규 실패 없음%s (기존 결함 %d건)\n" "$GREEN" "$NC" "$KNOWN"
  exit 0
fi
