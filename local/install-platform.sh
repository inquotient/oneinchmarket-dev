#!/usr/bin/env bash
# 플랫폼 계층 — ArgoCD 밖, sync wave -1 (COMPONENTS.md §9)
# infra/scripts/ 에는 argocd·istio·reloader 3종만 있고
# install-cilium.sh · install-operators.sh 는 파일 자체가 없다 (P0 블로커 #2).
set -Eeuo pipefail
trap 'echo "[platform][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

# ★★★ Cilium 은 k3s 버전과 **짝이 맞아야 한다** — Gotcha 47 과 같은 부류다.
#   2026-10-04 정정: 1.16.5 -> 1.20.2.
#   1.16 은 k8s 1.26~1.31 이고 1.19 는 `>=1.32 <1.36` 이라 **둘 다 우리
#   k3s v1.36.4 를 지원하지 않는다.** 1.20.2 가 k8s **1.33~1.36** 을 e2e
#   테스트한다(상류 compatibility 문서 실측, 2026-10-04). 이 값을 내리면
#   CNI 가 지원 밖으로 나가고 증상은 "노드가 Ready 가 안 된다" 로 뭉뚱그려져
#   원인이 멀어진다. ★ 추측하지 말고 상류 문서를 읽어서 정할 것.
CILIUM_VERSION="${CILIUM_VERSION:-1.20.2}"
# ★★ 아래 다섯은 **install-operators.sh 에 같은 이름이 또 있다** — Gotcha 117
#   이 경고한 "같은 목록을 두 곳에 적어 두는" 모양이고 실제로 어긋나 있다:
#   여기 ISTIO_VERSION 은 1.24.2 인데 install-operators.sh 는 1.31.0 이며
#   클러스터가 쓰는 값은 후자다. 이 파일은 Istio 를 설치하지 않으므로(그쪽이
#   한다) 지금 사고를 내지는 않지만, 고치려면 원천을 하나로 모아야 한다.
ISTIO_VERSION="${ISTIO_VERSION:-1.24.2}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.2.0}"
ECK_VERSION="${ECK_VERSION:-2.16.0}"
KYVERNO_VERSION="${KYVERNO_VERSION:-v1.13.2}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.2}"

log() { echo "[platform] $*"; }

# ── 1. Cilium CLI ──────────────────────────────────────────────
if ! command -v cilium >/dev/null 2>&1; then
  log "Cilium CLI 설치"
  CLI_VER=$(curl -sL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
  curl -sL --fail -o /tmp/cilium.tar.gz \
    "https://github.com/cilium/cilium-cli/releases/download/${CLI_VER}/cilium-linux-amd64.tar.gz"
  sudo tar xzf /tmp/cilium.tar.gz -C /usr/local/bin
fi
cilium version --client

# ── 2. Cilium — M1·M2 가 이 로컬 환경의 존재 이유다 ─────────────
#   M1 socketLB.hostNamespaceOnly=true
#     Cilium socketLB 는 connect() 시점 BPF cgroup 훅에서 목적지를 바꾼다.
#     그대로 두면 Istio ambient 의 ztunnel 이 인터셉트할 대상을 잃는다.
#     host 네임스페이스로 한정해 파드 트래픽은 정상 데이터패스를 타게 한다.
#   M2 cni.exclusive=false
#     istio-cni 가 체인에 끼어들 수 있게 한다.
#
# ★★ Hubble relay·UI 를 **처음부터 함께 켠다**(2026-09-11).
#   에이전트의 enable-hubble 은 원래도 true 였는데 **relay 도 UI 도 파드가
#   0개**였다 — 흐름을 모으기만 하고 아무도 읽지 않는 상태였다(실측).
#   Falcosidekick 의 Enabled Outputs: [](§8-35) · Reloader 어노테이션 65개에
#   컨트롤러 0개(Gotcha 84)와 **같은 부류**다: 설정은 있고, 아무도 읽지 않고,
#   오류는 나지 않는다.
#   ★ 값이 분명한 이유 — 이 클러스터는 ambient 라 정책 거부가 **타임아웃으로
#     보인다**(Gotcha 13·19·50). Hubble 은 누가 누구에게 막혔는지 직접 보여 준다.
#   ★★ resources 를 여기서 준다 — 나중에 kubectl 로 패치하면 이 스크립트를
#     다시 돌릴 때 지워진다(Gotcha 80).
if ! kubectl get ds -n kube-system cilium >/dev/null 2>&1; then
  log "Cilium ${CILIUM_VERSION} 설치 (M1 socketLB.hostNamespaceOnly · M2 cni.exclusive=false)"
  cilium install --version "${CILIUM_VERSION}" \
    --set socketLB.hostNamespaceOnly=true \
    --set cni.exclusive=false \
    --set k8sServiceHost=127.0.0.1 \
    --set k8sServicePort=6443 \
    --set operator.replicas=1 \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    --set hubble.relay.resources.requests.cpu=20m \
    --set hubble.relay.resources.requests.memory=64Mi \
    --set hubble.relay.resources.limits.memory=192Mi \
    --set hubble.ui.backend.resources.requests.memory=64Mi \
    --set hubble.ui.backend.resources.limits.memory=128Mi \
    --set hubble.ui.frontend.resources.requests.memory=32Mi \
    --set hubble.ui.frontend.resources.limits.memory=96Mi
else
  log "Cilium 이미 설치됨 — 건너뜀"
fi
log "Cilium 준비 대기"
cilium status --wait --wait-duration 5m

log "노드 Ready 대기"
kubectl wait --for=condition=Ready node --all --timeout=300s
kubectl get node -o wide

# ── 3. Gateway API CRD (waypoint Gateway 가 의존) ──────────────
log "Gateway API ${GATEWAY_API_VERSION}"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

log "완료. 다음: local/install-operators.sh"
