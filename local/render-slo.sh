#!/usr/bin/env bash
# Sloth 로 SLO 정의를 Prometheus 규칙으로 **생성**한다.
#
# ★ 왜 컨트롤러를 쓰지 않는가 — 이 클러스터에는 Prometheus Operator 가 없다
#   (실측: monitoring.coreos.com CRD 0개). Sloth 의 컨트롤러 모드는
#   PrometheusRule CR 을 만드는데 받을 곳이 없다. 규칙은 `prometheus-rules`
#   ConfigMap 에서 오므로 **생성해서 git 에 두는** 편이 맞다.
#   `render-ratelimit.py` 와 같은 모양이다(§8-90: 렌더 결과를 커밋할 것).
#
# ★★ `--check` 는 생성 결과가 git 과 다르면 1 을 돌려준다 — CI 게이트용이다.
#   정의만 고치고 렌더를 잊으면 규칙이 그대로인데, 그것이 git diff 에 드러난다.
#
# ★★★ 생성만 하면 **아무도 읽지 않는다.** Prometheus 의 `rule_files` 는
#   `/etc/prometheus/rules/*.yml` 이고 그 디렉터리에는 `prometheus-rules` ConfigMap
#   하나만 마운트된다. 그래서 이 스크립트는 생성 뒤에 `slo-to-configmap.py` 를 불러
#   그 ConfigMap 안으로 **넣는 것까지** 한다. 확장자는 `.yml` 이어야 한다.
#
# 사용
#   local/render-slo.sh            # slo/*.yaml -> slo/generated/*.rules.yaml
#   local/render-slo.sh --check    # 뒤처졌으면 1
set -Eeuo pipefail
trap 'echo "[slo][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HERE/slo"
OUT="$SRC/generated"
IMAGE="${SLOTH_IMAGE:-ghcr.io/slok/sloth:v0.16.0}"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1
mkdir -p "$OUT"
log() { echo "[slo] $*"; }

# ★ 노드의 podman 으로 돌린다 — build-images.sh 와 같은 경로다.
#   클러스터에 워크로드를 하나 더 두지 않는다(생성은 빌드 시점의 일이다).
runner=""
command -v podman >/dev/null 2>&1 && runner="sudo podman"
[ -z "$runner" ] && command -v docker >/dev/null 2>&1 && runner="docker"
[ -z "$runner" ] && { echo "[slo] podman·docker 가 없다" >&2; exit 1; }

rc=0
for f in "$SRC"/*.yaml; do
  [ -e "$f" ] || continue
  base="$(basename "$f" .yaml)"
  dst="$OUT/${base}.rules.yaml"
  tmp="$(mktemp)"
  log "생성 ${base}"
  # ★ `generate` 는 stdin 을 읽지 않는다 — `-i` 로 파일을 줘야 한다
  #   (실측: `error: "generate" command failed: stat : no such file or directory`).
  #   그래서 정의 디렉터리를 마운트해 컨테이너 안 경로로 넘긴다.
  $runner run --rm -v "$SRC":/slo:ro "$IMAGE" generate -i "/slo/$(basename "$f")" > "$tmp"
  # ★ 빈 출력을 통과시키지 말 것 — sloth 가 조용히 실패하면 0바이트가 나오고
  #   그것을 커밋하면 규칙이 사라진다(Gotcha 117 의 "비어 있지 않다" 가드 교훈).
  if ! grep -q 'record:\|alert:' "$tmp"; then
    echo "[slo] ${base}: 생성 결과에 규칙이 없다 — 정의를 볼 것" >&2
    rm -f "$tmp"; exit 1
  fi
  if [ "$CHECK" = "1" ]; then
    if ! diff -q "$tmp" "$dst" >/dev/null 2>&1; then
      echo "[slo] ${base}: 생성 결과가 git 과 다르다 — render-slo.sh 를 돌리고 커밋할 것" >&2
      rc=1
    fi
    rm -f "$tmp"
  else
    mv "$tmp" "$dst"
    log "  -> ${dst#$HERE/} ($(grep -c 'record:\|alert:' "$dst") 규칙)"
  fi
done
# ── prometheus-rules ConfigMap 에 주입 ──────────────────────
# ★ 생성만 하고 끝내면 아무도 읽지 않는다 — 이 레포가 반복해 밟은 부류다
#   (Gotcha 33·84·141). 주입까지 해야 도입이 끝난다.
CM="$HERE/kubernetes/base/observability/prometheus/prometheus-rules.yaml"
if [ "$CHECK" = "1" ]; then
  python3 "$HERE/local/slo-to-configmap.py" "$CM" "$OUT" --check || rc=1
else
  python3 "$HERE/local/slo-to-configmap.py" "$CM" "$OUT"
fi

[ "$CHECK" = "1" ] && [ "$rc" = "0" ] && log "생성 결과가 git 과 같다"
exit $rc
