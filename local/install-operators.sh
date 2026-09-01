#!/usr/bin/env bash
# 오퍼레이터 계층 — ArgoCD 밖, sync wave -1 (COMPONENTS.md §9)
# P0 블로커 #2: infra/scripts/ 에 install-operators.sh 가 존재하지 않는다.
#
# 선행: local/install-platform.sh (Cilium + Gateway API)
set -Eeuo pipefail
trap 'echo "[operators][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

ISTIO_VERSION="${ISTIO_VERSION:-1.24.2}"
ECK_VERSION="${ECK_VERSION:-3.2.0}"           # v1 이 쓰던 버전 (COMPONENTS.md §1-3)
KYVERNO_VERSION="${KYVERNO_VERSION:-v1.13.2}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.2}"

log() { echo "[operators] $*"; }

# ── 1. Istio Ambient (M3 — istio-cni 포함) ─────────────────────
# Cilium 이 CNI 를 표준 경로(/etc/cni/net.d · /opt/cni/bin)로 정규화해 두어
# k3s 특유의 경로 오버라이드가 필요 없다. cni.exclusive=false(M2)가 전제다.
if ! command -v istioctl >/dev/null 2>&1; then
  log "istioctl ${ISTIO_VERSION} 설치"
  curl -sL "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz" \
    -o /tmp/istio.tgz
  tar xzf /tmp/istio.tgz -C /tmp
  sudo install -m 0755 "/tmp/istio-${ISTIO_VERSION}/bin/istioctl" /usr/local/bin/istioctl
fi
istioctl version --remote=false

if ! kubectl get ns istio-system >/dev/null 2>&1; then
  log "Istio ambient 프로파일 설치 (istiod · ztunnel · istio-cni)"
  istioctl install --set profile=ambient -y
else
  log "istio-system 이미 존재 — 건너뜀"
fi

# ── 2. ECK Operator ────────────────────────────────────────────
# v1 에는 설치 코드가 있었으나 v2 에서 사라졌다 (COMPONENTS.md §1-3).
log "ECK ${ECK_VERSION}"
kubectl apply --server-side -f "https://download.elastic.co/downloads/eck/${ECK_VERSION}/crds.yaml"
kubectl apply -f "https://download.elastic.co/downloads/eck/${ECK_VERSION}/operator.yaml"

# ── 3. Kyverno ─────────────────────────────────────────────────
# 정책 6종은 base 에 있으나 컨트롤러 설치 경로가 없었다.
log "Kyverno ${KYVERNO_VERSION}"
kubectl apply --server-side -f "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/install.yaml"

# ── 4. cert-manager ────────────────────────────────────────────
# v1 에는 Issuer/Certificate 가 있었다. v2 는 TODO-02 로 남아 있다.
log "cert-manager ${CERT_MANAGER_VERSION}"
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

# ── 5. 대기 및 검증 ────────────────────────────────────────────
log "오퍼레이터 Ready 대기"
kubectl -n istio-system    rollout status deploy/istiod                 --timeout=300s || true
kubectl -n istio-system    rollout status ds/ztunnel                    --timeout=300s || true
kubectl -n elastic-system  rollout status statefulset/elastic-operator  --timeout=300s || true
kubectl -n kyverno         rollout status deploy/kyverno-admission-controller --timeout=300s || true
kubectl -n cert-manager    rollout status deploy/cert-manager-webhook   --timeout=300s || true

log "── 설치 결과 ──"
kubectl get pods -A -o wide --no-headers | awk '{print $1"\t"$2"\t"$4}' | sort
echo
log "── CNI 체인 (istio-cni 가 Cilium 옆에 들어왔는지) ──"
sudo ls -l /etc/cni/net.d/
log "완료."
