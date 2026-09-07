#!/usr/bin/env bash
# 오퍼레이터 계층 — ArgoCD 밖, sync wave -1 (COMPONENTS.md §9)
# P0 블로커 #2: infra/scripts/ 에 install-operators.sh 가 존재하지 않는다.
#
# 선행: local/install-platform.sh (Cilium + Gateway API)
set -Eeuo pipefail
trap 'echo "[operators][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

# ★★ Istio 와 k3s 는 **짝이 맞아야 한다.** Istio 지원 표(§8-73):
#   1.24 -> k8s 1.28~1.31 · 1.29 -> 1.31~1.35 · 1.30·1.31 -> **1.32~1.36**
#   즉 이 값을 올릴 때는 bootstrap-wsl-k3s.sh 의 K3S_VERSION 도 함께 봐야 한다.
#   1.31 은 k8s 1.32 미만에서 돌지 않는다.
ISTIO_VERSION="${ISTIO_VERSION:-1.31.0}"
ECK_VERSION="${ECK_VERSION:-3.2.0}"           # v1 이 쓰던 버전 (COMPONENTS.md §1-3)
KYVERNO_VERSION="${KYVERNO_VERSION:-v1.13.2}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.2}"
# 4단계(security-min)
TETRAGON_VERSION="${TETRAGON_VERSION:-1.7.1}"
TRIVY_OPERATOR_VERSION="${TRIVY_OPERATOR_VERSION:-v0.34.0}"
POLICY_REPORTER_VERSION="${POLICY_REPORTER_VERSION:-policy-reporter-3.10.0}"
EXTERNAL_SECRETS_VERSION="${EXTERNAL_SECRETS_VERSION:-2.10.0}"
RELOADER_VERSION="${RELOADER_VERSION:-2.2.16}"   # app v1.4.21

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
  # ★ 기본 requests 가 단일 노드에 과하다 — istiod 2Gi · ztunnel 512Mi 를
  #   예약하는데 실측은 69Mi · 6Mi 다(2026-09-03). 이 둘만으로 노드
  #   allocatable 의 4.8% 를 잡고 있었다.
  #   istioctl 설치라 kustomize 오버레이가 닿지 않으므로 여기서 넣는다.
  istioctl install --set profile=ambient -y     --set values.pilot.resources.requests.memory=256Mi     --set values.pilot.resources.requests.cpu=100m     --set values.ztunnel.resources.requests.memory=128Mi     --set values.ztunnel.resources.requests.cpu=50m
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
# ★ ghcr.io 의 OCI 경로(oci://ghcr.io/cilium/charts/tetragon)는 익명 pull 이
#   403 denied 다. helm repo 를 쓴다.
helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update >/dev/null
helm template tetragon cilium/tetragon \
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
# ★ 기본 동시 스캔 10개는 이 노드에 과하다. 설치 직후 워크로드 40여 개를
#   한꺼번에 스캔하며 메모리 limits 를 102%까지 밀어 올렸다. 2로 낮춘다.
#   키 이름은 OPERATOR_CONCURRENT_SCAN_JOBS_LIMIT 이다.
#   scanJob.concurrentLimit 같은 이름은 없다 — 잘못 쓰면 조용히 무시되는
#   키가 하나 늘 뿐이고 동시 스캔은 그대로 10개다.
# ★★ `OPERATOR_SCAN_JOB_TTL` 은 정리 주기가 아니라 **처리량을 정하는 값**이다.
#   끝난 Job(Complete·Failed)이 TTL 동안 **동시 실행 슬롯을 붙잡는다** —
#   실측: 슬롯 2개가 끝난 Job 둘에 물려 새 스캔이 하나도 뜨지 않다가,
#   그 둘을 지우자 10초 만에 새 Job 2개가 떴다.
#   10m × 2 슬롯이면 **시간당 12건**이라 워크로드 140여 개의 백로그가
#   끝나지 않는다. 증상은 "스캔이 안 된다" 가 아니라 **"내 워크로드 차례가
#   영영 오지 않는다"** 라 오퍼레이터가 도는 것만 보고는 알 수 없다.
#   1m 로 줄인다 — 실패한 Job 을 들여다볼 시간이 짧아지는 것이 대가다.
kubectl -n trivy-system patch cm trivy-operator-config --type merge -p '{"data":{"OPERATOR_CONCURRENT_SCAN_JOBS_LIMIT":"2","OPERATOR_CONCURRENT_NODE_COLLECTOR_LIMIT":"1","OPERATOR_SCAN_JOB_TTL":"1m"}}' || true
# ★ GitLab 컨테이너 레지스트리는 **평문 HTTP** 다(§8-79). Trivy 는 기본적으로
#   HTTPS 로 붙으므로 알려 주지 않으면 스캔이 실패한다.
#   `nonSslRegistry` 와 `insecureRegistry` 는 다른 것이다 —
#   전자는 "평문 HTTP", 후자는 "TLS 인데 인증서를 검증하지 않음" 이다.
#   여기는 TLS 자체가 없으므로 nonSslRegistry 가 맞다. 잘못 쓰면
#   조용히 무시되고 스캔은 계속 실패한다.
#   ★ 이 설정이 없으면 `docker/` 로컬 빌드 이미지 9종이 **한 번도
#     스캔되지 않는다** — 오퍼레이터가 도는 것과 스캔이 되는 것은 다르다.
# ★ Trivy 0.74 는 스캔 Job 에서 캐시 잠금을 놓지 않는다 —
#     ERROR Failed to acquire cache or database lock
#     FATAL unable to initialize fs cache: cache may be in use by another
#           process: timeout
#   초기화 컨테이너가 DB 를 내려받고 끝난 뒤 본 컨테이너가 같은 emptyDir 을
#   쓰는데 거기서 걸린다(볼륨은 파드 안에서만 공유되므로 Job 간 경합이 아니다).
#   0.66.0 으로 내리면 스캔 파드가 Error 대신 Completed 로 끝난다.
#   ★ 실패가 **간헐적**이라 "가끔 되니 괜찮다" 로 읽히기 쉽다 — 리포트가
#     하루 종일 드문드문 생겼다. 판정은 대상 워크로드별 리포트 유무로 할 것.
kubectl -n trivy-system patch cm trivy-operator-trivy-config --type merge -p '{"data":{"trivy.tag":"0.66.0"}}' || true
kubectl -n trivy-system patch cm trivy-operator-trivy-config --type merge -p '{"data":{"trivy.nonSslRegistry.gitlab":"gitlab-registry.local.svc.cluster.local:5050"}}' || true

# 5-2-a. Trivy 서버 — ClientServer 모드 (§8-79)
#
# ★ Standalone 은 이 클러스터에서 쓸 수 없다. 스캔 Job 의 **컨테이너마다**
#   취약점 DB 를 여는데, 한 Job 의 컨테이너들이 같은 emptyDir 를 공유한 채
#   병렬로 돌아 BoltDB 잠금을 다툰다:
#     FATAL init error: DB error: vulnerability database may be in use by
#           another process: timeout
#   초기화 컨테이너를 가진 워크로드가 전부 걸리고, **로컬 빌드 이미지 9종은
#   전부 초기화 컨테이너를 동반한다**(ranger 플러그인·wait-deps·render-config).
#   ★★ 부분 성공이라 건수로는 드러나지 않는다 — 판정은 대상 워크로드별
#     리포트 유무로 할 것.
#
# ★ 서버와 클라이언트의 **버전이 같아야 한다** — local/trivy-server.yaml 의
#   이미지 태그와 위 `trivy.tag` 를 함께 움직일 것.
log "Trivy 서버 (ClientServer 모드)"
kubectl apply -f "$(dirname "$0")/trivy-server.yaml"
kubectl -n trivy-system rollout status deploy/trivy-server --timeout=900s || true
kubectl -n trivy-system patch cm trivy-operator-trivy-config --type merge -p '{"data":{"trivy.mode":"ClientServer","trivy.serverURL":"http://trivy-server.trivy-system.svc.cluster.local:4954"}}' || true

kubectl -n trivy-system rollout restart deploy/trivy-operator || true

# 5-2-b. External Secrets Operator — OpenBao 를 시크릿 원천으로 (§8-81)
#
# ★ 왜 필요한가 — 이 레포의 시크릿 관리는 오래도록 미작동이었다
#   (.enc.yaml 12개가 자리표시자이고 전부 주석 처리되어 렌더 결과에 Secret 이
#    0개다). ESO 가 OpenBao 의 값을 읽어 Kubernetes Secret 으로 **물질화**하면
#   워크로드는 지금 쓰는 secretKeyRef 를 그대로 두고도 원천만 바뀐다.
#   Vault Enterprise 의 Secrets Sync 자리이기도 하다(부록 A-2).
#
# ★ ESO 는 정적 install.yaml 을 내지 않는다(릴리스 자산이 Helm 차트 tgz 뿐).
#   Tetragon 과 같이 **Helm 을 템플릿 렌더러로만** 쓴다 — 클러스터에 Helm
#   릴리스가 남지 않으므로 "No Helm" 원칙과 어긋나지 않는다.
log "External Secrets Operator ${EXTERNAL_SECRETS_VERSION}"
kubectl create ns external-secrets --dry-run=client -o yaml | kubectl apply -f -
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update >/dev/null
# ★ 기본 requests 가 이 노드에 과하다. 다른 오퍼레이터와 같은 취급으로 낮춘다.
helm template external-secrets external-secrets/external-secrets   --version "${EXTERNAL_SECRETS_VERSION}"   --namespace external-secrets   --include-crds   --set installCRDs=true   --set resources.requests.cpu=25m   --set resources.requests.memory=64Mi   --set webhook.resources.requests.cpu=10m   --set webhook.resources.requests.memory=32Mi   --set certController.resources.requests.cpu=10m   --set certController.resources.requests.memory=32Mi   | kubectl apply --server-side --force-conflicts -f -

# 5-3. Policy Reporter (Kyverno·Trivy 결과 집계)
#
# ★ kustomize 의 원격 git fetch 에는 27초 하드 타임아웃이 있어 이 저장소에서는
#   늘 실패한다("hit 27s timeout running git fetch"). 얕은 클론 후 로컬에서 읽는다.
#   배포물은 kustomization 이 아니라 install.yaml 한 장이고,
#   네임스페이스를 스스로 만들지 않는다.
log "Policy Reporter ${POLICY_REPORTER_VERSION}"
kubectl create ns policy-reporter --dry-run=client -o yaml | kubectl apply -f -
PR_DIR=$(mktemp -d)
git clone --depth 1 --branch "${POLICY_REPORTER_VERSION}" -q \
  https://github.com/kyverno/policy-reporter "$PR_DIR"
kubectl apply --server-side --force-conflicts \
  -f "$PR_DIR/manifests/policy-reporter/install.yaml"
rm -rf "$PR_DIR"
# ── 6. 대기 및 검증 ────────────────────────────────────────────
# ── 8. Reloader (ConfigMap/Secret 변경 시 워크로드 재시작) ─────
#
# ★★ 왜 필요한가 — `reloader.stakater.com/auto: "true"` 어노테이션이 워크로드
#   **65개**에 이미 붙어 있는데 컨트롤러가 없었다. 어노테이션은 아무 일도 하지
#   않고 오류도 내지 않는다(Gotcha 84). 드러난 계기는 trino-config 를 고쳤는데
#   파드가 재시작하지 않은 것이다(§8-94).
#
# ★★★ 날짜가 붙은 문제였다 — 로테이션 CronJob 7종이 전부 활성이고 다음 발화가
#   2026-09-15 03:00 이다. 그날 Secret 이 바뀌는데 아무도 파드를 재시작하지
#   않으면 워크로드가 옛 자격을 든 채 남는다. 로테이션 Job 중 스스로
#   rollout restart 를 하는 것은 0개다(§9-11).
#
# ★ scoped 모드다 — `reloader.namespaces` 로 local 만 본다. 어노테이션이 붙은
#   65개가 전부 local 에 있어서다. 그러면 **ClusterRole 이 만들어지지 않고**
#   local·reloader 두 네임스페이스에 Role 만 생긴다(최소 권한).
#   ★ 키 이름은 `namespaces` 다. `watchNamespaces` 는 **존재하지 않는 키이고
#     helm 은 조용히 무시한다** — 실제로 처음에 그렇게 써서 Role 이 local 에
#     생기지 않았고, 렌더를 보지 않았으면 "설치했는데 아무 일도 안 한다" 가
#     됐을 것이다(§8-96).
#
# ★★ reload-strategy=annotations 를 쓴다. 기본(env-vars)은 컨테이너에 해시
#   환경변수를 넣어 ArgoCD 가 드리프트로 본다. annotations 는 파드 템플릿
#   어노테이션 한 줄이라 Application 의 ignoreDifferences 로 정확히 지목할 수
#   있다 — argocd/applications/oneinchmarket-local.yaml 에 함께 넣었다.
log "Reloader ${RELOADER_VERSION}"
kubectl create ns reloader --dry-run=client -o yaml | kubectl apply -f -
helm repo add stakater https://stakater.github.io/stakater-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm template reloader stakater/reloader   --version "${RELOADER_VERSION}"   --namespace reloader   --set reloader.watchGlobally=false   --set "reloader.namespaces={local}"   --set reloader.reloadStrategy=annotations   --set reloader.deployment.containerSecurityContext.allowPrivilegeEscalation=false   --set reloader.deployment.containerSecurityContext.readOnlyRootFilesystem=true   --set "reloader.deployment.containerSecurityContext.capabilities.drop={ALL}"   --set reloader.deployment.resources.requests.cpu=10m   --set reloader.deployment.resources.requests.memory=64Mi   --set reloader.deployment.resources.limits.memory=192Mi   | kubectl apply --server-side --force-conflicts -f -

log "오퍼레이터 Ready 대기"
kubectl -n istio-system    rollout status deploy/istiod                 --timeout=300s || true
kubectl -n istio-system    rollout status ds/ztunnel                    --timeout=300s || true
kubectl -n elastic-system  rollout status statefulset/elastic-operator  --timeout=300s || true

# ★ ECK 오퍼레이터도 ambient 에 편입한다.
#   elastic-operator 는 Elasticsearch 의 부트스트랩·헬스·라이선스를 9200 으로
#   관리한다. 메시 밖에 두면 ztunnel 에 **신원 없이** 도착하고,
#   allow-observability-access 의 principal 규칙은 어느 것도 매칭되지 않아
#   ES 가 관리 불능이 된다. 이 네임스페이스는 오버레이가 만들지 않으므로
#   여기서 라벨을 건다(§8-47).
kubectl label ns elastic-system istio.io/dataplane-mode=ambient --overwrite
kubectl -n kyverno         rollout status deploy/kyverno-admission-controller --timeout=300s || true
kubectl -n cert-manager    rollout status deploy/cert-manager-webhook   --timeout=300s || true
kubectl -n tetragon        rollout status ds/tetragon                    --timeout=300s || true
kubectl -n trivy-system    rollout status deploy/trivy-operator          --timeout=300s || true
kubectl -n external-secrets rollout status deploy/external-secrets       --timeout=300s || true
kubectl -n policy-reporter rollout status deploy/policy-reporter         --timeout=300s || true

log "── 설치 결과 ──"
kubectl get pods -A -o wide --no-headers | awk '{print $1"\t"$2"\t"$4}' | sort
echo
log "── CNI 체인 (istio-cni 가 Cilium 옆에 들어왔는지) ──"
sudo ls -l /etc/cni/net.d/
log "완료."
