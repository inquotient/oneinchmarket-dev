#!/usr/bin/env bash
# Chainsaw 시나리오(tests/chainsaw/)를 돌린다 — 노드 103(control-plane), root.
#   bash local/run-chainsaw.sh                 # 전부
#   bash local/run-chainsaw.sh kafka-edge-authz # 하나(디렉터리 이름)
#   bash local/run-chainsaw.sh --check          # 도구·클러스터 전제만
# Windows 에서(이 PC 에는 kubectl 이 없다):
#   git archive HEAD tests local/run-chainsaw.sh | ssh root@192.168.0.103 \
#     'rm -rf /tmp/oim-chainsaw && mkdir -p /tmp/oim-chainsaw && tar xm -C /tmp/oim-chainsaw && cd /tmp/oim-chainsaw && bash local/run-chainsaw.sh'
#   (tar 의 m — PC 와 노드 시계 차이로 나는 "타임스탬프가 앞으로" 경고를 없앤다)
#
# 종료 코드: 0 전부 통과 · 1 실패가 있다 · 2 측정 불가(도구·클러스터가 없다 — 통과로 접지 않는다, Gotcha 191).
#
# ★ Chainsaw 는 릴리스 바이너리를 sha256 고정으로 받아 판이 든 경로에 둔다(PATH 를 건드리지 않는다).
#   판을 올릴 때는 CHAINSAW_VERSION 과 CHAINSAW_SHA256 을 함께 바꿀 것 — checksums.txt 의 linux_amd64.tar.gz 줄이다.
# ★ 시나리오가 만드는 것: kn 의 ksvc 둘(끝나면 지운다) · edge.events 의 표식 메시지 하나. 나머지는 서버측 dry-run·조회다.
#   과금 경로(api 호스트·api-usage 토픽)는 건드리지 않는다. 단 Knative 시험 요청은 ingress 게이트웨이를 지나
#   subject 없는 계량 이벤트로 남는다(청구되지 않는다 — tests/chainsaw/knative-routing 머리말).
set -euo pipefail

CHAINSAW_VERSION=0.2.15
CHAINSAW_SHA256=295d226c89f126c0a97775d364be149f47a810c8a3f9829ee410583d0c1abe3c
BIN_DIR=/usr/local/lib/oim/chainsaw-${CHAINSAW_VERSION}
BIN=${BIN_DIR}/chainsaw
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TESTS=${ROOT}/tests/chainsaw

ensure_chainsaw() {
  if [ -x "$BIN" ] && "$BIN" version 2>/dev/null | grep -q "Version: ${CHAINSAW_VERSION}$"; then return 0; fi
  local tmp; tmp=$(mktemp -d)
  # -f: HTTP 오류에서 실패한다(404 본문을 쓰고 exit 0 하지 않게, Gotcha 148)
  curl -fsSL -o "$tmp/c.tgz" "https://github.com/kyverno/chainsaw/releases/download/v${CHAINSAW_VERSION}/chainsaw_linux_amd64.tar.gz" \
    || { echo "chainsaw 를 받지 못했다" >&2; rm -rf "$tmp"; return 2; }
  echo "${CHAINSAW_SHA256}  $tmp/c.tgz" | sha256sum -c --quiet - \
    || { echo "chainsaw 체크섬 불일치 — 설치하지 않는다" >&2; rm -rf "$tmp"; return 2; }
  tar xzf "$tmp/c.tgz" -C "$tmp" chainsaw
  install -D -m 0755 "$tmp/chainsaw" "$BIN"
  rm -rf "$tmp"
  "$BIN" version | grep -q "Version: ${CHAINSAW_VERSION}$"
}

preflight() {
  command -v kubectl >/dev/null || { echo "kubectl 이 없다" >&2; return 2; }
  command -v curl >/dev/null || { echo "curl 이 없다" >&2; return 2; }
  kubectl get --raw /readyz >/dev/null 2>&1 || { echo "API 서버에 닿지 못한다" >&2; return 2; }
  [ -d "$TESTS" ] || { echo "시나리오 디렉터리가 없다: $TESTS" >&2; return 2; }
}

ensure_chainsaw || exit 2
preflight || exit 2
if [ "${1:-}" = "--check" ]; then
  echo "chainsaw ${CHAINSAW_VERSION} · 클러스터 닿음 · 시나리오 $(find "$TESTS" -name chainsaw-test.yaml | wc -l)개"
  exit 0
fi

args=(test --config "$TESTS/.chainsaw.yaml")
if [ $# -gt 0 ]; then
  for t in "$@"; do
    [ -f "$TESTS/$t/chainsaw-test.yaml" ] || { echo "시나리오가 없다: $t" >&2; exit 2; }
    args+=(--test-dir "$TESTS/$t")
  done
else
  args+=(--test-dir "$TESTS")
fi

set +e
"$BIN" "${args[@]}"
rc=$?
set -e
[ $rc = 0 ] && exit 0 || exit 1
