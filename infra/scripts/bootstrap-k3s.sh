#!/usr/bin/env bash
# bootstrap-k3s.sh - k3s 클러스터 초기 설치 스크립트
# 사용법: ./bootstrap-k3s.sh <MASTER_IP> <WORKER_IPS...>
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.31.4+k3s1}"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <MASTER_IP> [WORKER_IP...]"
  echo "  MASTER_IP: k3s server 노드 IP"
  echo "  WORKER_IP: k3s agent 노드 IP (복수 가능)"
  exit 1
fi

MASTER_IP="$1"
shift
WORKER_IPS=("$@")

echo "=== k3s Server 설치: ${MASTER_IP} ==="
ssh root@"${MASTER_IP}" bash -s <<REMOTE
set -euo pipefail
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  INSTALL_K3S_EXEC="server \
    --disable traefik \
    --disable servicelb \
    --write-kubeconfig-mode 644 \
    --tls-san ${MASTER_IP} \
    --flannel-backend wireguard-native" \
  sh -
echo "k3s server 설치 완료"
REMOTE

echo "=== k3s 토큰 가져오기 ==="
K3S_TOKEN=$(ssh root@"${MASTER_IP}" cat /var/lib/rancher/k3s/server/node-token)

for WORKER_IP in "${WORKER_IPS[@]}"; do
  echo "=== k3s Agent 설치: ${WORKER_IP} ==="
  ssh root@"${WORKER_IP}" bash -s <<REMOTE
set -euo pipefail
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  K3S_URL="https://${MASTER_IP}:6443" \
  K3S_TOKEN="${K3S_TOKEN}" \
  sh -
echo "k3s agent 설치 완료: ${WORKER_IP}"
REMOTE
done

echo "=== kubeconfig 가져오기 ==="
scp root@"${MASTER_IP}":/etc/rancher/k3s/k3s.yaml ./kubeconfig.yaml
sed -i "s/127.0.0.1/${MASTER_IP}/g" ./kubeconfig.yaml
echo "kubeconfig 저장: ./kubeconfig.yaml"

echo "=== 클러스터 상태 확인 ==="
KUBECONFIG=./kubeconfig.yaml kubectl get nodes -o wide

echo "=== k3s 클러스터 부트스트랩 완료 ==="
