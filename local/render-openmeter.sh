#!/usr/bin/env bash
# OpenMeter 매니페스트 생성기 (ADR-072 ⓑ · ADR-073).
#
# 왜 렌더해서 커밋하는가 — OpenReplay·Tetragon 과 같다:
#   ① 배포 시점에 Helm 을 쓰지 않는다(ADR-003). `helm template` 은
#      **생성 도구**로만 쓴다.
#   ② 차트가 requests·limits 를 하나도 선언하지 않는다.
#   ③ 레포 규약 라벨(part-of·component)과 securityContext 를 차트가 붙이지 않는다.
#
# 재생성: bash local/render-openmeter.sh
set -Eeuo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="oci://ghcr.io/openmeterio/helm-charts/openmeter"
VERSION="${OPENMETER_VERSION:-1.0.0-beta.232}"
OUT="$REPO/kubernetes/overlays/local/openmeter/openmeter.yaml"

mkdir -p "$(dirname "$OUT")"
helm template openmeter "$CHART" --version "$VERSION" \
  -f "$REPO/local/openmeter-values.yaml" \
  --namespace local > /tmp/om-raw.yaml

python3 "$REPO/local/render-openmeter.py" "$OUT"
echo "생성: $OUT ($(wc -l < "$OUT") 줄)"
