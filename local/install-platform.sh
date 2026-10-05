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

# ★★★ k8sServiceHost — 2026-10-04 에 `127.0.0.1` 에서 **서버 노드 IP** 로
#   고쳤다. 그 값은 **단일 노드 전제**였고, 에이전트를 조인하는 순간 깨진다.
#   실측(192.168.0.104 조인 직후):
#     · 에이전트의 `ss -lntp` 에 6443 리스너가 **없다**(*:10250 뿐)
#     · cilium 의 첫 init 컨테이너 `config` 가 1분을 재시도하다
#       `dial tcp 127.0.0.1:6443: connect: connection refused` 로 죽고
#       `Build config failed` -> CrashLoopBackOff
#     · 그래서 그 노드는 `cni plugin not initialized` 로 **영원히 NotReady**
#   ★ 증상이 원인을 가리키지 않는다 — 노드가 NotReady 라 CNI/커널을 의심하게
#     되는데, 진짜 단서는 **init 컨테이너 로그 한 줄**이다. 파드 목록에는
#     `Init:0/6` 으로만 보이고(6개 중 첫째에서 막힌 것) 그 사실이 보이지 않는다.
#   ★★ "k3s 에이전트는 127.0.0.1:6443 에 로컬 로드밸런서를 띄운다" 는 말을
#     믿지 말 것 — 이 버전(v1.36.4+k3s1)에서는 **열려 있지 않다.** 실측으로
#     확인했고, 추측으로 그렇게 적었다가 한 번 틀렸다.
#   ★ 그래서 **노드 IP 가 고정이어야** 이 값이 성립한다(Gotcha 49 와 같은 뿌리).
K8S_SERVICE_HOST="${K8S_SERVICE_HOST:-$(ip -o -4 addr show dev "$(ip -o -4 route show default | awk '{print $5; exit}')" scope global | awk '{print $4}' | cut -d/ -f1 | head -1)}"
[ -n "$K8S_SERVICE_HOST" ] || { echo "[platform] k8sServiceHost 를 정하지 못했다 — K8S_SERVICE_HOST 로 넘길 것" >&2; exit 1; }
case "$K8S_SERVICE_HOST" in 127.*|localhost) echo "[platform] k8sServiceHost 가 루프백(${K8S_SERVICE_HOST})이다 — 에이전트가 붙지 못한다" >&2; exit 1;; esac
# ★★★ 2026-10-05: 쓰이지 않던 버전 변수 넷을 **지웠다**(ISTIO·ECK·KYVERNO·
#   CERT_MANAGER). 선언만 되어 있고 이 파일에서 참조가 **0건**이었다(실측).
#   그런데 같은 이름이 `install-operators.sh` 에도 있고 값이 달랐다 —
#   여기 ISTIO_VERSION 은 1.24.2, 그쪽은 1.31.0 이며 클러스터가 쓰는 값은
#   후자다. 사고를 내지는 않았지만 **다음 사람이 어느 쪽이 진짜인지 알 수 없다.**
#   Gotcha 117("같은 목록을 두 곳에 적어 두고 주석으로 막지 말 것")의 가장 싼
#   형태다 — 쓰지 않는 쪽을 지우면 원천이 하나가 된다.
# ★ 이 파일이 실제로 설치하는 것은 **Cilium 과 Gateway API 둘뿐**이다.
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.2.0}"

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
    --set k8sServiceHost="${K8S_SERVICE_HOST}" \
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
