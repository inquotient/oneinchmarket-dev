terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }
}

resource "hcloud_ssh_key" "deploy" {
  name       = "${var.env}-deploy-key"
  public_key = var.ssh_key
}

resource "hcloud_server" "worker" {
  count       = var.worker_count
  name        = "${var.env}-worker-${count.index + 1}"
  server_type = var.server_type
  location    = var.location
  image       = "ubuntu-24.04"
  ssh_keys    = [hcloud_ssh_key.deploy.id]

  labels = {
    role = "worker"
    env  = var.env
  }
}
