#!/usr/bin/env bash
# 7-3: Trivy 이미지 CVE 스캔 + 렌더 매니페스트 설정 스캔 + 시크릿 스캔
# 사전 조건: trivy 설치 (https://trivy.dev)
# 실행: ./03-trivy-scan.sh [namespace]
#
# ★★★ 2026-10-09: 자체 판정을 넣었다. 그 전에는 SCAN_PASS·SCAN_FAIL 을
#   **출력만 하고 종료 코드로 내보내지 않아**, 취약한 이미지를 몇 개 찾아도
#   run-all.sh 가 "통과" 로 집계했다(Gotcha 191 의 거짓 증명).
# ★★ 판정을 셋으로 나눈 것이 핵심이다 — 스캔에 **실패한 이미지**를 "깨끗하다"
#   와 같은 칸에 넣으면 안 된다. Trivy 는 이 호스트에서 큰 이미지를 받다
#   끊기거나(Gotcha 132) 임시 디렉터리 충돌로 죽은 적이 있다(Gotcha 131).
#   그런 이미지는 **측정 불가**다.
# ★ 차단은 CRITICAL 로 좁힌다. HIGH 까지 실패로 세면 빨간불이 상수가 되고
#   사람이 배경으로 읽는다 — 렌더 기준으로도 372건이던 자리다(Gotcha 90).
#   HIGH 는 수치로 계속 보이게 둔다.
#
# 판정: 0 통과 · 1 실패(CRITICAL 있음) · 2 측정 불가

set -euo pipefail
cd "$(dirname "$0")/../.."

NAMESPACE="${1:-}"   # 이 스크립트는 클러스터를 보지 않는다. 인자는 받되 쓰지 않는다.

FAILED=0
WARNED=0
UNMEASURED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ★ 도구가 없으면 측정 불가(2)다. 옛 판은 trivy 가 없어도 끝까지 돌며
#   "Clean 0 / Vulnerable 0" 을 찍고 종료 코드 0 을 돌려줬다.
if ! command -v trivy >/dev/null 2>&1; then
  echo "[측정 불가] trivy 가 설치되어 있지 않다 (https://trivy.dev)"
  echo "            설치한 뒤 다시 돌릴 것. 이것은 통과가 아니다."
  exit 2
fi

echo "============================================"
echo "  Trivy 보안 스캔"
echo "============================================"
printf "  trivy %s\n" "$(trivy --version 2>/dev/null | head -1)"
echo ""

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# ───────────────────────────────────────────────
echo "=== Part 1: 이미지 CVE 스캔 ==="
echo ""
IMAGES=$(grep -rh 'image:' kubernetes/base --include='*.yaml' \
  | grep -v '#' \
  | grep -v 'kyverno' \
  | sed 's/.*image:[[:space:]]*//' \
  | sed 's/"//g' \
  | sort -u)

NIMG=$(printf '%s\n' "$IMAGES" | grep -c . || true)
if [ "${NIMG:-0}" = 0 ]; then
  printf "${BLUE}[측정 불가]${NC} kubernetes/base 에서 이미지를 하나도 뽑지 못했다 — 추출식이 어긋났다\n"
  UNMEASURED=$((UNMEASURED + 1))
else
  printf "  대상 이미지 %s개\n\n" "$NIMG"
  CLEAN=0; HIGHONLY=0; CRIT=0; UNSCAN=0
  for img in $IMAGES; do
    printf "  %-58s ... " "$img"
    if ! trivy image --severity HIGH,CRITICAL --format json --quiet \
           -o "$TMPD/scan.json" "$img" >/dev/null 2>&1; then
      # ★ 스캔 실패를 "깨끗" 과 같은 칸에 넣지 않는다.
      printf "${BLUE}측정 불가${NC} (스캔 실패)\n"
      UNSCAN=$((UNSCAN + 1))
      continue
    fi
    NC_=$(grep -o '"Severity":[[:space:]]*"CRITICAL"' "$TMPD/scan.json" 2>/dev/null | wc -l | tr -d ' ')
    NH_=$(grep -o '"Severity":[[:space:]]*"HIGH"' "$TMPD/scan.json" 2>/dev/null | wc -l | tr -d ' ')
    if [ "${NC_:-0}" -gt 0 ]; then
      printf "${RED}CRITICAL %s${NC} (HIGH %s)\n" "$NC_" "$NH_"
      CRIT=$((CRIT + 1))
    elif [ "${NH_:-0}" -gt 0 ]; then
      printf "${YELLOW}HIGH %s${NC}\n" "$NH_"
      HIGHONLY=$((HIGHONLY + 1))
    else
      printf "${GREEN}깨끗${NC}\n"
      CLEAN=$((CLEAN + 1))
    fi
  done
  echo ""
  printf "  깨끗 %s · HIGH 만 %s · ${RED}CRITICAL %s${NC} · ${BLUE}측정 불가 %s${NC}\n" \
    "$CLEAN" "$HIGHONLY" "$CRIT" "$UNSCAN"
  [ "$CRIT" -gt 0 ]   && FAILED=$((FAILED + CRIT))
  [ "$HIGHONLY" -gt 0 ] && WARNED=$((WARNED + HIGHONLY))
  [ "$UNSCAN" -gt 0 ] && UNMEASURED=$((UNMEASURED + UNSCAN))
fi
echo ""
# ───────────────────────────────────────────────
echo "=== Part 2: 매니페스트 설정 스캔 (렌더 기준) ==="
echo ""
# ★★★ 옛 판은 'trivy config kubernetes/' 로 **소스 트리**를 스캔했다. 그것은
#   Gotcha 90 이 명시적으로 금지한 것이다 — kustomize 패치 조각에는
#   securityContext·probe 가 없으니 전부 지적되고, 실측 338건 중 149건이
#   패치 파일 3개에서 나왔다. **렌더를 스캔해야 한다.**
RENDER=""
if command -v kustomize >/dev/null 2>&1; then
  kustomize build kubernetes/overlays/local > "$TMPD/render.yaml" 2>/dev/null && RENDER="$TMPD/render.yaml"
fi
if [ -z "$RENDER" ]; then
  kubectl kustomize kubernetes/overlays/local > "$TMPD/render.yaml" 2>/dev/null && RENDER="$TMPD/render.yaml"
fi
# ★ 가드를 "파일이 있다" 로 두지 말 것 — 빈 파일도 있는 파일이다(Gotcha 117·148).
#   알려진 값이 실제로 들어 있는지로 판정한다.
if [ -n "$RENDER" ] && grep -q '^kind: Deployment' "$RENDER" 2>/dev/null; then
  NDOC=$(grep -c '^kind: ' "$RENDER" || true)
  printf "  렌더 성공 — 오브젝트 %s개\n\n" "$NDOC"
  if trivy config --severity CRITICAL --quiet "$RENDER" > "$TMPD/cfg.txt" 2>&1; then
    NCFG=$(grep -c 'CRITICAL' "$TMPD/cfg.txt" || true)
    if [ "${NCFG:-0}" -gt 0 ]; then
      printf "${RED}[FAIL]${NC} 렌더 매니페스트에 CRITICAL 설정 결함 %s건\n" "$NCFG"
      sed -n '1,40p' "$TMPD/cfg.txt"
      FAILED=$((FAILED + 1))
    else
      printf "${GREEN}[OK]${NC}   렌더 매니페스트에 CRITICAL 설정 결함 없음\n"
    fi
    # HIGH 는 차단하지 않고 수치만 — 렌더 기준으로도 수백 건이다(Gotcha 90).
    if trivy config --severity HIGH --quiet "$RENDER" > "$TMPD/cfgh.txt" 2>&1; then
      NH2=$(grep -c 'HIGH' "$TMPD/cfgh.txt" || true)
      printf "  (HIGH %s건 — 차단하지 않고 수치로 남긴다)\n" "${NH2:-0}"
    fi
  else
    printf "${BLUE}[측정 불가]${NC} trivy config 가 실패했다\n"
    UNMEASURED=$((UNMEASURED + 1))
  fi
else
  printf "${BLUE}[측정 불가]${NC} overlays/local 렌더에 실패했다 — kustomize·kubectl 을 확인할 것\n"
  printf "            ★ 소스 트리를 대신 스캔하지 않는다. 패치 조각을 완성된\n"
  printf "              매니페스트로 읽어 거짓 발견을 쏟아내기 때문이다(Gotcha 90)\n"
  UNMEASURED=$((UNMEASURED + 1))
fi
echo ""

# ───────────────────────────────────────────────
echo "=== Part 3: 파일시스템 시크릿 스캔 ==="
echo ""
# ★ 플래그 이름이 버전에 따라 다르다 — 새 trivy 는 --scanners, 옛것은
#   --security-checks 다. 둘 다 시도하고, 둘 다 안 되면 측정 불가로 적는다.
#   옛 판은 '|| true' 로 끝나 **실패와 발견 0건이 구분되지 않았다.**
SECRC=99
if trivy fs --scanners secret --quiet . > "$TMPD/sec.txt" 2>&1; then
  SECRC=0
elif trivy fs --security-checks secret --quiet . > "$TMPD/sec.txt" 2>&1; then
  SECRC=0
fi
if [ "$SECRC" = 0 ]; then
  NSEC=$(grep -ciE 'secret|password|token' "$TMPD/sec.txt" || true)
  if [ "${NSEC:-0}" -gt 0 ]; then
    # ★ 찾았다는 것이 위험하다는 뜻은 아니다 — 자리표시자와 보안 문서 자신이
    #   잡힌다(Gotcha 75). 그래서 수치로 남기고 사람이 가른다.
    printf "${YELLOW}[WARN]${NC} 시크릿 탐지 후보 %s줄 — 자리표시자·문서 오탐이 섞인다(Gotcha 75)\n" "$NSEC"
    sed -n '1,25p' "$TMPD/sec.txt"
    WARNED=$((WARNED + 1))
  else
    printf "${GREEN}[OK]${NC}   시크릿 탐지 0건\n"
  fi
else
  printf "${BLUE}[측정 불가]${NC} trivy fs 시크릿 스캔이 실패했다(--scanners·--security-checks 둘 다)\n"
  UNMEASURED=$((UNMEASURED + 1))
fi
echo ""

# ───────────────────────────────────────────────
echo "============================================"
echo "  Trivy 스캔 결과"
echo "============================================"
printf "  실패: %d (CRITICAL)\n" "$FAILED"
printf "  경고: %d (HIGH·탐지 후보 — 차단하지 않는다)\n" "$WARNED"
printf "  측정 불가: %d\n" "$UNMEASURED"
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
