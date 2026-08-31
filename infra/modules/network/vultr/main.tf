terraform {
  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.19"
    }
  }
}

resource "vultr_vpc" "main" {
  description    = "${var.env}-network"
  region         = var.region
  v4_subnet      = cidrhost(var.subnet_cidr, 0)
  v4_subnet_mask = parseint(split("/", var.subnet_cidr)[1], 10)
}

# --- Bastion 방화벽: SSH + WireGuard만 공개 ---
resource "vultr_firewall_group" "bastion" {
  description = "${var.env}-bastion-firewall"
}

resource "vultr_firewall_rule" "bastion_ssh" {
  firewall_group_id = vultr_firewall_group.bastion.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "22"
}

resource "vultr_firewall_rule" "bastion_wireguard" {
  firewall_group_id = vultr_firewall_group.bastion.id
  protocol          = "udp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "51820"
}

# --- k3s 노드 방화벽: 공인 IP 전면 차단 (VPC 전용) ---
# 빈 방화벽 그룹 = default deny all inbound on public IP
# VPC 트래픽은 방화벽을 우회하므로 노드 간 통신 정상 동작
# 모든 접근은 WireGuard VPN → bastion → VPC 경유
resource "vultr_firewall_group" "k3s" {
  description = "${var.env}-k3s-firewall"
}
