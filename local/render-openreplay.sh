#!/usr/bin/env bash
# OpenReplay 차트 **참고 렌더** — 판을 올릴 때 상류가 무엇을 바꿨는지 보는 도구다.
#
# ★★★ 2026-11-08 부터 이것은 배포 파일을 만들지 않는다.
#   원천은 커밋된 `kubernetes/overlays/local/openreplay/openreplay.yaml` 이다. 생성 뒤에 손으로
#   고친 것이 쌓여(Ingress 제거 · 전용 SA · 이미지 완전지정 · securityContext · 자원 조정 ·
#   ASSETS_ORIGIN · USE_CORS · 공유 PVC · 마이그레이션 훅 · CLICKHOUSE_PASSWORD 등) 다시 생성하면
#   그것들이 조용히 사라졌다 — 1.28 로 올릴 때 실제로 그렇게 됐다(CLAUDE.md Gotcha 222 ① · 224).
#   그 수정을 전부 생성기 코드로 옮기는 대신 **생성기를 비교 도구로 낮췄다**: 수정이 두 곳(코드와
#   파일)에 사는 것이 어긋남의 원인이었기 때문이다(Gotcha 71·117 과 같은 자리).
#
# 쓰는 법 — 판을 올릴 때:
#   1) 두 판의 차트를 받는다(예: openreplay 레포의 scripts/helmcharts, 태그별로)
#   2) bash local/render-openreplay.sh <새 판 차트 디렉터리> [<옛 판 차트 디렉터리>]
#   3) 출력된 차이(이미지 태그 · 컨테이너별 env 이름 · 오브젝트 증감)를 보고
#      openreplay.yaml 에 **손으로** 옮긴다. 렌더 결과를 그대로 덮어쓰지 말 것.
#   옛 판을 주면 "상류가 바꾼 것"(옛 판 → 새 판)을, 안 주면 "커밋된 파일과 새 판의 차이"를 보인다.
#   후자에는 우리가 일부러 바꾼 것(위 목록)이 섞여 나온다.
# ★ 렌더는 /tmp 에만 쓴다. 레포의 어떤 파일도 바꾸지 않는다.
# ★ 렌더에 차트가 생성한 개인키(site.key 등)와 미치환 템플릿 상수가 들어 있을 수 있다 —
#   결과 파일을 레포에 복사하지 말 것(Gotcha 172).
set -Eeuo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEW="${1:-}"
OLD="${2:-}"
CUR="$REPO/kubernetes/overlays/local/openreplay/openreplay.yaml"
WORK="$(mktemp -d /tmp/or-render.XXXXXX)"

[ -n "$NEW" ] || { echo "사용: $0 <새 판 차트 디렉터리(scripts/helmcharts)> [<옛 판 차트 디렉터리>]" >&2; exit 2; }
command -v helm >/dev/null || { echo "helm 이 없다" >&2; exit 2; }

render() {  # $1 차트 디렉터리 · $2 출력
  [ -d "$1/openreplay" ] || { echo "차트가 없다: $1/openreplay" >&2; exit 2; }
  helm template openreplay "$1/openreplay" \
    -f "$1/vars.yaml" \
    -f "$REPO/local/openreplay-values.yaml" \
    --namespace local > "$WORK/raw.yaml"
  # render-openreplay.py 는 엔드포인트·Secret 참조를 이 클러스터 것으로 바꾼다 —
  # 비교에서 그 차이(우리가 의도한 것)가 소음으로 나오지 않게 하려는 것이다.
  python3 "$REPO/local/render-openreplay.py" "$WORK/raw.yaml" "$2"
}

render "$NEW" "$WORK/new.yaml"
if [ -n "$OLD" ]; then
  render "$OLD" "$WORK/old.yaml"
  BASE="$WORK/old.yaml"; LABEL="옛 판 차트"
else
  BASE="$CUR"; LABEL="커밋된 openreplay.yaml"
fi
python3 "$REPO/local/render-openreplay.py" --compare "$BASE" "$WORK/new.yaml" "$LABEL"
echo "렌더 결과: $WORK (레포에 복사하지 말 것)"
