#!/usr/bin/env bash
# OneinchMarket v2 - 보안 검증 전체 실행
# 사전 조건: kubectl, kubesec, trivy 설치
# 실행: ./run-all.sh [namespace]
#
# 검증 항목:
#   7-1: kube-bench (CIS Benchmark)
#   7-2: kubesec (매니페스트 보안 점수)
#   7-3: Trivy (이미지 CVE + 매니페스트 스캔)
#   7-4: 로테이션 dry-run (CronJob/Secret/RBAC 확인)
#   7-5: Kyverno Audit (정책 위반 리포트)
#   7-6: Falco 규칙 테스트 (Job 배포로 트리거)
#   7-7: NetworkPolicy (허용/차단 트래픽)
#   7-8: age 키 백업 검증
#   7-9: RBAC 최소 권한 감사

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="${1:-dev}"
REPORT_DIR="/tmp/oneinchmarket-security-report-$(date +%Y%m%d-%H%M%S)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

mkdir -p "$REPORT_DIR"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   OneinchMarket v2 - 보안 검증 리포트            ║"
echo "║   Namespace: ${NAMESPACE}                              ║"
echo "║   Date: $(date +%Y-%m-%d\ %H:%M:%S)                    ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "리포트 저장 경로: $REPORT_DIR"
echo ""

run_test() {
  local num=$1
  local name=$2
  local script=$3

  echo ""
  printf "${BOLD}━━━ %s: %s ━━━${NC}\n" "$num" "$name"
  echo ""

  if [ -f "$SCRIPT_DIR/$script" ]; then
    if [[ "$script" == *.sh ]]; then
      bash "$SCRIPT_DIR/$script" "$NAMESPACE" 2>&1 | tee "$REPORT_DIR/${num}.txt" || true
    elif [[ "$script" == *.yaml ]]; then
      echo "매니페스트: $script"
      echo "실행: kubectl apply -f $SCRIPT_DIR/$script"
      echo "(클러스터 연결 시 자동 실행)"
      kubectl apply -f "$SCRIPT_DIR/$script" 2>&1 | tee "$REPORT_DIR/${num}.txt" || \
        echo "  클러스터 미연결 - 스킵" | tee "$REPORT_DIR/${num}.txt"
    fi
  else
    echo "스크립트 없음: $script" | tee "$REPORT_DIR/${num}.txt"
  fi
}

# 로컬 실행 가능한 검증 (클러스터 불필요)
echo "═══════════════════════════════════════════"
echo "  Part A: 로컬 검증 (클러스터 불필요)"
echo "═══════════════════════════════════════════"

run_test "7-2" "kubesec 매니페스트 보안 점수" "02-kubesec-scan.sh"
run_test "7-3" "Trivy 이미지/매니페스트 스캔" "03-trivy-scan.sh"
run_test "7-8" "age 키 백업 검증" "08-age-key-backup.sh"

# 클러스터 필요한 검증
echo ""
echo "═══════════════════════════════════════════"
echo "  Part B: 클러스터 검증 (kubectl 필요)"
echo "═══════════════════════════════════════════"

if kubectl cluster-info > /dev/null 2>&1; then
  run_test "7-1" "kube-bench CIS Benchmark" "01-kube-bench.yaml"
  run_test "7-4" "로테이션 Dry-Run" "04-rotation-dryrun.sh"
  run_test "7-5" "Kyverno Audit 리포트" "05-kyverno-audit.sh"
  run_test "7-6" "Falco 규칙 테스트" "06-falco-test.yaml"
  run_test "7-7" "NetworkPolicy 검증" "07-netpol-test.sh"
  run_test "7-9" "RBAC 최소 권한 감사" "09-rbac-audit.sh"
else
  echo ""
  printf "${YELLOW}[SKIP]${NC} 클러스터 미연결 - Part B 검증을 건너뜁니다.\n"
  echo "  클러스터 연결 후 개별 스크립트를 실행하세요."
fi

# 요약
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   검증 완료                                      ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║                                                  ║"
echo "║   리포트: $REPORT_DIR"
echo "║                                                  ║"
echo "║   개별 실행:                                      ║"
echo "║     ./02-kubesec-scan.sh    (로컬)               ║"
echo "║     ./03-trivy-scan.sh      (로컬)               ║"
echo "║     ./08-age-key-backup.sh  (로컬)               ║"
echo "║     kubectl apply -f 01-kube-bench.yaml          ║"
echo "║     ./04-rotation-dryrun.sh (클러스터)            ║"
echo "║     ./05-kyverno-audit.sh   (클러스터)            ║"
echo "║     kubectl apply -f 06-falco-test.yaml          ║"
echo "║     ./07-netpol-test.sh     (클러스터)            ║"
echo "║     ./09-rbac-audit.sh      (클러스터)            ║"
echo "║                                                  ║"
echo "╚══════════════════════════════════════════════════╝"
