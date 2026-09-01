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
# 4단계(security-min)
TETRAGON_VERSION="${TETRAGON_VERSION:-1.7.1}"
TRIVY_OPERATOR_VERSION="${TRIVY_OPERATOR_VERSION:-v0.34.0}"
POLICY_REPORTER_VERSION="${POLICY_REPORTER_VERSION:-policy-reporter-3.10.0}"

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


# ── 5. 4단계: security-min 오퍼레이터 계층 ─────────────────────
# Tetragon·Trivy Operator·Policy Reporter 는 CRD 를 동반하므로 ArgoCD
# 밖(wave -1)에서 설치한다. Kyverno·ECK 와 같은 취급이다.

# 5-1. Tetragon (eBPF 런타임 관측·강제)
#
# ★ Helm 을 "설치 도구"가 아니라 "템플릿 렌더러"로만 쓴다.
#   Tetragon 은 정적 매니페스트를 배포하지 않는다(Helm 차트뿐). 그렇다고
#   2천 줄을 손으로 옮기면 업스트림 추종이 불가능해진다. 그래서
#   `helm template | kubectl apply` 로 렌더만 하고 릴리스는 남기지 않는다.
#   클러스터에 Helm 릴리스 시크릿이 생기지 않으므로 "No Helm" 원칙
#   (CLAUDE.md)과 어긋나지 않는다 — 배포 시점에 Helm 이 관여하지 않는다.
#
#   Falco 와 역할이 겹친다. Falco 는 시스템콜 기반 탐지, Tetragon 은
#   eBPF 기반 관측 + 정책 강제(TracingPolicy)다. 목표 아키텍처가 둘 다
#   포함하므로 병존시킨다.
if ! command -v helm >/dev/null 2>&1; then
  log "helm 설치 (렌더 전용)"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
fi
log "Tetragon ${TETRAGON_VERSION}"
kubectl create ns tetragon --dry-run=client -o yaml | kubectl apply -f -
helm template tetragon oci://ghcr.io/cilium/charts/tetragon \
  --version "${TETRAGON_VERSION#v}" \
  --namespace tetragon \
  --set tetragon.resources.limits.memory=512Mi \
  --set tetragon.resources.requests.memory=128Mi \
  --set tetragon.resources.requests.cpu=50m \
  --set tetragonOperator.resources.limits.memory=128Mi \
  --set tetragonOperator.resources.requests.memory=64Mi \
  --set tetragonOperator.resources.requests.cpu=10m \
  | kubectl apply --server-side --force-conflicts -f -

# 5-2. Trivy Operator (이미지·설정 취약점 상시 스캔)
#
# base/observability/trivy 의 주간 CronJob 과 역할이 겹친다. 오퍼레이터는
# 워크로드 변경을 감지해 즉시 스캔하고 결과를 CRD 로 남긴다.
# CronJob 제거는 dev/prod 에도 영향이 있어 별도 결정으로 둔다.
log "Trivy Operator ${TRIVY_OPERATOR_VERSION}"
kubectl apply --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/aquasecurity/trivy-operator/${TRIVY_OPERATOR_VERSION}/deploy/static/trivy-operator.yaml"

# 5-3. Policy Reporter (Kyverno·Trivy 결과 집계)
log "Policy Reporter ${POLICY_REPORTER_VERSION}"
kubectl apply --server-side --force-conflicts -k \
  "https://github.com/kyverno/policy-reporter/manifests/policy-reporter?ref=${POLICY_REPORTER_VERSION}"
# ── 6. 대기 및 검증 ────────────────────────────────────────────
log "오퍼레이터 Ready 대기"
kubectl -n istio-system    rollout status deploy/istiod                 --timeout=300s || true
kubectl -n istio-system    rollout status ds/ztunnel                    --timeout=300s || true
kubectl -n elastic-system  rollout status statefulset/elastic-operator  --timeout=300s || true
kubectl -n kyverno         rollout status deploy/kyverno-admission-controller --timeout=300s || true
kubectl -n cert-manager    rollout status deploy/cert-manager-webhook   --timeout=300s || true
kubectl -n tetragon        rollout status ds/tetragon                    --timeout=300s || true
kubectl -n trivy-system    rollout status deploy/trivy-operator          --timeout=300s || true
kubectl -n policy-reporter rollout status deploy/policy-reporter         --timeout=300s || true

log "── 설치 결과 ──"
kubectl get pods -A -o wide --no-headers | awk '{print $1"\t"$2"\t"$4}' | sort
echo
log "── CNI 체인 (istio-cni 가 Cilium 옆에 들어왔는지) ──"
sudo ls -l /etc/cni/net.d/
log "완료."
