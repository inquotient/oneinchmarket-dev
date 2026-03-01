#!/usr/bin/env bash
# bootstrap-k3s.sh - k3s 클러스터 초기 설치 스크립트 (bastion 경유)
# 사용법: ./bootstrap-k3s.sh <BASTION_IP> <MASTER_PRIVATE_IP> <WORKER_PRIVATE_IP...>
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.31.4+k3s1}"
WG_SUBNET="10.10.0.0/24"
WG_SERVER_IP="10.10.0.1"
WG_CLIENT_IP="10.10.0.2"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

if [ $# -lt 2 ]; then
  echo "Usage: $0 <BASTION_IP> <MASTER_PRIVATE_IP> [WORKER_PRIVATE_IP...]"
  echo ""
  echo "  BASTION_IP:         bastion 노드 공인 IP (WireGuard VPN)"
  echo "  MASTER_PRIVATE_IP:  master 노드 VPC 사설 IP"
  echo "  WORKER_PRIVATE_IP:  worker 노드 VPC 사설 IP (복수 가능)"
  echo ""
  echo "Terraform output에서 IP 확인:"
  echo "  cd infra/environments/dev && tofu output"
  exit 1
fi

BASTION_IP="$1"
MASTER_PRIVATE_IP="$2"
shift 2
WORKER_PRIVATE_IPS=("$@")

# bastion 경유 SSH 헬퍼
# ProxyCommand으로 jump host에도 SSH_OPTS 적용 (호스트 키 검증 스킵)
PROXY_CMD="ssh ${SSH_OPTS} -W %h:%p root@${BASTION_IP}"
ssh_bastion() { ssh ${SSH_OPTS} root@"${BASTION_IP}" "$@"; }
ssh_via_bastion() {
  local target_ip="$1"; shift
  ssh ${SSH_OPTS} -o "ProxyCommand=${PROXY_CMD}" root@"${target_ip}" "$@"
}
scp_via_bastion() {
  local target_ip="$1" remote_path="$2" local_path="$3"
  scp ${SSH_OPTS} -o "ProxyCommand=${PROXY_CMD}" root@"${target_ip}":"${remote_path}" "${local_path}"
}

# ======================================================================
echo "=== [1/7] Bastion WireGuard VPN 설정: ${BASTION_IP} ==="
# ======================================================================
ssh_bastion bash -s <<REMOTE
set -euo pipefail

# ufw 비활성화 (Vultr 방화벽 그룹 사용)
if command -v ufw &>/dev/null; then
  ufw disable 2>/dev/null || true
fi

hostnamectl set-hostname dev-bastion

# WireGuard 설치
apt-get update -qq && apt-get install -y -qq wireguard

# 키 생성
mkdir -p /etc/wireguard
if [ ! -f /etc/wireguard/server.key ]; then
  wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub
  wg genkey | tee /etc/wireguard/client.key | wg pubkey > /etc/wireguard/client.pub
  chmod 600 /etc/wireguard/*.key
fi

SERVER_PRIVKEY=\$(cat /etc/wireguard/server.key)
CLIENT_PUBKEY=\$(cat /etc/wireguard/client.pub)

# WireGuard 서버 설정
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = 51820
PrivateKey = \${SERVER_PRIVKEY}
PostUp = iptables -t nat -A POSTROUTING -s ${WG_SUBNET} ! -o wg0 -j MASQUERADE; sysctl -w net.ipv4.ip_forward=1
PostDown = iptables -t nat -D POSTROUTING -s ${WG_SUBNET} ! -o wg0 -j MASQUERADE

[Peer]
PublicKey = \${CLIENT_PUBKEY}
AllowedIPs = ${WG_CLIENT_IP}/32
EOF

chmod 600 /etc/wireguard/wg0.conf

# WireGuard 시작
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

echo "WireGuard 서버 설정 완료"
REMOTE

# 클라이언트 설정 파일 가져오기
echo "--- WireGuard 클라이언트 설정 생성 ---"
SERVER_PUBKEY=$(ssh_bastion cat /etc/wireguard/server.pub)
CLIENT_PRIVKEY=$(ssh_bastion cat /etc/wireguard/client.key)

cat > ./wireguard-client.conf <<EOF
[Interface]
Address = ${WG_CLIENT_IP}/24
PrivateKey = ${CLIENT_PRIVKEY}

[Peer]
PublicKey = ${SERVER_PUBKEY}
Endpoint = ${BASTION_IP}:51820
AllowedIPs = ${WG_SUBNET}, 10.0.1.0/24
PersistentKeepalive = 25
EOF
echo "WireGuard 클라이언트 설정 저장: ./wireguard-client.conf"

# ======================================================================
echo "=== [2/7] Master ufw 비활성화 및 hostname 설정 ==="
# ======================================================================
ssh_via_bastion "${MASTER_PRIVATE_IP}" bash -s <<'REMOTE'
set -euo pipefail
if command -v ufw &>/dev/null; then ufw disable 2>/dev/null || true; fi
hostnamectl set-hostname dev-master-1
REMOTE

# ======================================================================
echo "=== [3/7] k3s Server 설치: ${MASTER_PRIVATE_IP} ==="
# ======================================================================
ssh_via_bastion "${MASTER_PRIVATE_IP}" bash -s <<REMOTE
set -euo pipefail
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  INSTALL_K3S_EXEC="server \
    --node-name dev-master-1 \
    --disable traefik \
    --disable servicelb \
    --write-kubeconfig-mode 644 \
    --tls-san ${MASTER_PRIVATE_IP} \
    --flannel-backend wireguard-native" \
  sh -
echo "k3s server 설치 완료"
REMOTE

# ======================================================================
echo "=== [4/7] k3s 토큰 가져오기 ==="
# ======================================================================
K3S_TOKEN=$(ssh_via_bastion "${MASTER_PRIVATE_IP}" cat /var/lib/rancher/k3s/server/node-token)

# ======================================================================
echo "=== [5/7] k3s Agent 설치: ${#WORKER_PRIVATE_IPS[@]}대 ==="
# ======================================================================
WORKER_INDEX=0
for WORKER_IP in "${WORKER_PRIVATE_IPS[@]}"; do
  WORKER_INDEX=$((WORKER_INDEX + 1))
  NODE_NAME="dev-worker-${WORKER_INDEX}"

  echo "--- Worker ${WORKER_INDEX}: ${WORKER_IP} (${NODE_NAME}) ---"
  ssh_via_bastion "${WORKER_IP}" bash -s <<REMOTE
set -euo pipefail
if command -v ufw &>/dev/null; then ufw disable 2>/dev/null || true; fi
hostnamectl set-hostname ${NODE_NAME}
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  K3S_URL="https://${MASTER_PRIVATE_IP}:6443" \
  K3S_TOKEN="${K3S_TOKEN}" \
  INSTALL_K3S_EXEC="agent --node-name ${NODE_NAME}" \
  sh -
echo "k3s agent 설치 완료: ${NODE_NAME}"
REMOTE
done

# ======================================================================
echo "=== [6/7] kubeconfig 가져오기 ==="
# ======================================================================
scp_via_bastion "${MASTER_PRIVATE_IP}" /etc/rancher/k3s/k3s.yaml ./kubeconfig.yaml
sed -i "s/127.0.0.1/${MASTER_PRIVATE_IP}/g" ./kubeconfig.yaml
echo "kubeconfig 저장: ./kubeconfig.yaml"
echo "  (WireGuard VPN 연결 후 사용 가능)"

# ======================================================================
echo "=== [7/7] 노드 Ready 대기 ==="
# ======================================================================
EXPECTED_NODES=$(( 1 + ${#WORKER_PRIVATE_IPS[@]} ))
TIMEOUT=120
ELAPSED=0
while true; do
  READY_NODES=$(ssh_via_bastion "${MASTER_PRIVATE_IP}" \
    "kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true")
  if [ "${READY_NODES}" -ge "${EXPECTED_NODES}" ]; then
    echo "모든 노드 Ready (${READY_NODES}/${EXPECTED_NODES})"
    break
  fi
  if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
    echo "WARNING: 타임아웃 ${TIMEOUT}초 — Ready 노드: ${READY_NODES}/${EXPECTED_NODES}"
    break
  fi
  echo "대기 중... Ready 노드: ${READY_NODES}/${EXPECTED_NODES} (${ELAPSED}s/${TIMEOUT}s)"
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

ssh_via_bastion "${MASTER_PRIVATE_IP}" "kubectl get nodes -o wide"

echo ""
echo "=== k3s 클러스터 부트스트랩 완료 ==="
echo ""
echo "다음 단계:"
echo "  1. WireGuard 클라이언트에 ./wireguard-client.conf 임포트"
echo "  2. VPN 연결 후: KUBECONFIG=./kubeconfig.yaml kubectl get nodes"
