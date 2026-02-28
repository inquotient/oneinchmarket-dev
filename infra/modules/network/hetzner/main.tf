terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }
}

resource "hcloud_network" "main" {
  name     = "${var.env}-network"
  ip_range = var.network_cidr
}

resource "hcloud_network_subnet" "k3s" {
  network_id   = hcloud_network.main.id
  type         = "cloud"
  network_zone = "ap-southeast"
  ip_range     = var.subnet_cidr
}

resource "hcloud_firewall" "k3s" {
  name = "${var.env}-k3s-firewall"

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22"
    source_ips = ["0.0.0.0/0"]
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "6443"
    source_ips = [var.network_cidr]
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "443"
    source_ips = ["0.0.0.0/0"]
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "80"
    source_ips = ["0.0.0.0/0"]
  }
}
