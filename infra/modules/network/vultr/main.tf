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

resource "vultr_firewall_group" "k3s" {
  description = "${var.env}-k3s-firewall"
}

resource "vultr_firewall_rule" "ssh" {
  firewall_group_id = vultr_firewall_group.k3s.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "22"
}

resource "vultr_firewall_rule" "https" {
  firewall_group_id = vultr_firewall_group.k3s.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "443"
}

resource "vultr_firewall_rule" "http" {
  firewall_group_id = vultr_firewall_group.k3s.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "80"
}
