#!/usr/bin/env bash
# WSL2 단일 노드 k3s 부트스트랩 — B안(설계 전 구성요소, zram 활용)
#
# 선행 조건
#   1. local/wslconfig → C:\Users\<user>\.wslconfig 복사 후 `wsl --shutdown`
#   2. Docker Desktop 종료 (docker-desktop 배포판이 메모리를 경합)
#   3. 이 레포를 WSL ext4 로 clone (/mnt/c 는 I/O 가 극도로 느리다)
#
# 산정 근거: docs/LOCAL-DEPLOYMENT.md
set -Eeuo pipefail
trap 'echo "[bootstrap][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

K3S_VERSION="${K3S_VERSION:-v1.31.4+k3s1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo "[bootstrap] $*"; }

# ── 0. 사전 점검 ────────────────────────────────────────────────
log "사전 점검"
MEM_GIB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
[ "$MEM_GIB" -ge 40 ] || { echo "FAIL: MemTotal ${MEM_GIB}GiB — .wslconfig 미적용. wsl --shutdown 후 재시도"; exit 1; }
[ -r /sys/kernel/btf/vmlinux ]         || { echo "FAIL: BTF 없음 — Falco/Tetragon/Cilium CO-RE 불가"; exit 1; }
[ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ] || { echo "FAIL: cgroup v2 아님"; exit 1; }
[ "$(ps -p 1 -o comm=)" = systemd ]    || { echo "FAIL: systemd 미기동 — /etc/wsl.conf 에 systemd=true"; exit 1; }
log "OK — MemTotal ${MEM_GIB}GiB · BTF · cgroup2 · systemd"

# ── 1. zram 압축 스왑 ───────────────────────────────────────────
log "zram 설정 (disksize 32G / mem_limit 14G / lzo-rle)"
sudo install -m 0644 "${REPO_ROOT}/local/zram-swap.service" /etc/systemd/system/zram-swap.service
sudo install -m 0644 "${REPO_ROOT}/local/99-k3s-zram.conf"  /etc/sysctl.d/99-k3s-zram.conf
sudo systemctl daemon-reload
sudo systemctl enable --now zram-swap
sudo sysctl --system >/dev/null

# THP 는 부팅 파라미터라 sysctl 로 못 바꾼다. 런타임 설정.
echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null

log "스왑 구성:"; swapon --show

# ── 2. k3s ─────────────────────────────────────────────────────
# NodeSwap 은 kubelet 플래그라 설치 시점에만 정할 수 있다.
# 나중에 켜려면 systemd 유닛 편집 + 재시작 = 전 파드 재시작.
log "k3s ${K3S_VERSION} 설치"
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - server \
  --write-kubeconfig-mode 644 \
  --disable traefik \
  --disable servicelb \
  --flannel-backend=none \
  --disable-network-policy \
  --kubelet-arg=fail-swap-on=false \
  --kubelet-arg=feature-gates=NodeSwap=true \
  --kubelet-arg=memory-swap.swap-behavior=LimitedSwap \
  --kubelet-arg=memory-throttling-factor=0.8 \
  --kubelet-arg=system-reserved=memory=1Gi,cpu=500m \
  --kubelet-arg=kube-reserved=memory=1Gi,cpu=500m \
  --kubelet-arg='eviction-hard=memory.available<300Mi'

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
mkdir -p ~/.kube && sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config && chmod 600 ~/.kube/config

# --flannel-backend=none 이므로 Cilium 설치 전까지 아무것도 스케줄되지 않는다.
log "k3s 기동 대기 (CNI 부재로 NotReady 가 정상)"
until kubectl get node >/dev/null 2>&1; do sleep 3; done
kubectl get node

# ── 3. StorageClass 'standard' 별칭 ────────────────────────────
# 배포 블로커 #5 — 전 PVC 가 존재하지 않는 'standard' 를 참조한다.
# 매니페스트 9개를 고치는 것보다 별칭 한 장이 싸다.
log "StorageClass 'standard' 생성"
kubectl apply -f "${REPO_ROOT}/local/storageclass-standard.yaml"

log "완료. 다음: local/install-platform.sh (Cilium · Gateway API · Istio · 오퍼레이터)"
