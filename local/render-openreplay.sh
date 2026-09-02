#!/usr/bin/env bash
# OpenReplay 매니페스트 생성기.
#
# 왜 렌더해서 커밋하는가 —
#   ① 이 레포는 배포 시점에 Helm 을 쓰지 않는다(ADR-003). Tetragon 과 같은
#      방식으로 `helm template` 은 **생성 도구**로만 쓴다.
#   ② 차트가 워크로드 20종의 requests·limits 를 **하나도 선언하지 않는다.**
#      limits 없는 파드를 이미 111% 인 노드에 올리면 무한정 먹는다.
#      여기서 주입한다.
#   ③ 레포 규약 라벨(part-of·component)도 차트가 붙이지 않는다.
#
# 재생성: bash local/render-openreplay.sh
set -Eeuo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${OPENREPLAY_SRC:-/tmp/or-tar/openreplay-main/scripts/helmcharts}"
OUT="$REPO/kubernetes/overlays/local/openreplay/openreplay.yaml"

[ -d "$SRC/openreplay" ] || { echo "차트가 없다: $SRC" >&2; exit 1; }

helm template openreplay "$SRC/openreplay" \
  -f "$SRC/vars.yaml" \
  -f "$REPO/local/openreplay-values.yaml" \
  --namespace local > /tmp/or-raw.yaml

python3 "$REPO/local/render-openreplay.py" "$OUT"
