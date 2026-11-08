#!/usr/bin/env bash
# Kyverno 컨트롤러 플래그 조정 — PolicyViolation 이벤트를 끈다.
#
# 사용: bash local/kyverno-tune.sh [--check]
#   --check  바꾸지 않고 확인만 한다(0 통과 · 1 다름 · 2 측정 불가)
#
# 왜(2026-11-08 실측): 클러스터 이벤트 22,081건 중 19,962건(90%)이 Kyverno 의
#   `PolicyViolation` 이었다(admission 13,822 · background scan 6,140). local 의 정책은
#   전부 Audit 이라 그 이벤트는 **PolicyReport 에 이미 있는 내용의 사본**이고, 이벤트는
#   etcd 에 쓰이는 객체라 쓰기 부하의 큰 덩이였다(API 쓰기 중 events POST 가 lease 다음).
#   그 쓰기 부하가 SQLite/kine 을 죽였다(Gotcha 222 ⑤ · 223).
# ★ 위반 정보는 사라지지 않는다 — PolicyReport·Policy Reporter·05-kyverno-audit.sh §2 가
#   그것을 읽는다. 이벤트를 읽는 곳은 05 §4(참고용)뿐이었다.
# ★ Enforce 거부는 이벤트가 아니라 **어드미션 응답**으로 사용자에게 돌아가므로 prod 에서도
#   잃는 것이 없다.
# ★★ install.yaml 을 다시 적용하면 플래그가 상류 기본값으로 돌아간다(Gotcha 80) —
#   install-operators.sh 가 Kyverno 를 적용한 직후 이것을 부른다. 손으로 다시 적용했다면
#   이것도 다시 돌릴 것.
# 복귀 조건: 위반을 이벤트로만 받는 소비자가 생기면 그 정책만 다시 켤 방법을 찾을 것 —
#   전역으로 되돌리지 말 것.
set -euo pipefail

WANT="--omitEvents=PolicyApplied,PolicySkipped,PolicyViolation"
NS=kyverno
DEPLOYS="kyverno-admission-controller kyverno-background-controller kyverno-reports-controller"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

command -v kubectl >/dev/null || { echo "[kyverno-tune] kubectl 없음 — 측정 불가" >&2; exit 2; }
command -v python3 >/dev/null || { echo "[kyverno-tune] python3 없음 — 측정 불가" >&2; exit 2; }

# 배포 JSON 을 받아 한 줄을 낸다: OK <값> | DIFF <값> <json-patch> | ERR <개수>
plan() {
  python3 -c '
import json, sys
want = sys.argv[1]
d = json.load(sys.stdin)
hits = []
for ci, c in enumerate(d["spec"]["template"]["spec"]["containers"]):
    for ai, a in enumerate(c.get("args") or []):
        if a.startswith("--omitEvents="):
            hits.append((ci, ai, a))
if len(hits) != 1:
    print("ERR", len(hits)); sys.exit(0)
ci, ai, a = hits[0]
if a == want:
    print("OK", a)
else:
    path = "/spec/template/spec/containers/%d/args/%d" % (ci, ai)
    p = [{"op": "test", "path": path, "value": a}, {"op": "replace", "path": path, "value": want}]
    print("DIFF", a, json.dumps(p, separators=(",", ":")))
' "$WANT"
}

rc=0
for d in $DEPLOYS; do
  if ! j=$(kubectl -n "$NS" get deploy "$d" -o json 2>/dev/null); then
    echo "[kyverno-tune] $d: 받지 못했다 — 측정 불가"; rc=2; continue
  fi
  read -r state cur patch <<<"$(printf '%s' "$j" | plan)"
  case "$state" in
    OK)   echo "[kyverno-tune] $d: 이미 맞다 ($cur)" ;;
    ERR)  echo "[kyverno-tune] $d: --omitEvents 인자가 정확히 하나가 아니다(${cur}개) — 손으로 볼 것"; rc=1 ;;
    DIFF)
      if [ "$CHECK" = 1 ]; then
        echo "[kyverno-tune] $d: 다르다 ($cur)"; [ "$rc" = 0 ] && rc=1
      else
        kubectl -n "$NS" patch deploy "$d" --type=json -p "$patch" >/dev/null
        # ★ 되읽어 확인한다 — patch 가 조용히 빗나가면 아무 일도 하지 않은 것과 같다(Gotcha 86)
        got=$(kubectl -n "$NS" get deploy "$d" -o json | plan | awk '{print $1}')
        if [ "$got" = OK ]; then
          echo "[kyverno-tune] $d: 바꿨다 ($cur -> $WANT)"
        else
          echo "[kyverno-tune] $d: 바꾼 뒤 되읽은 값이 다르다 — 실패"; rc=1
        fi
      fi ;;
    *) echo "[kyverno-tune] $d: 판정 실패"; rc=2 ;;
  esac
done

if [ "$CHECK" = 0 ] && [ "$rc" = 0 ]; then
  for d in $DEPLOYS; do
    kubectl -n "$NS" rollout status deploy "$d" --timeout=300s >/dev/null || { echo "[kyverno-tune] $d 롤아웃 미완"; rc=1; }
  done
fi
exit "$rc"
