terraform {
  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.19"
    }
  }
}

resource "vultr_ssh_key" "deploy" {
  name    = "${var.env}-deploy-key"
  ssh_key = var.ssh_key
}

resource "vultr_instance" "worker" {
  count       = var.worker_count
  label       = "${var.env}-worker-${count.index + 1}"
  plan        = var.plan
  region      = var.region
  os_id       = 2284 # Ubuntu 24.04
  ssh_key_ids = [vultr_ssh_key.deploy.id]

  tags = ["worker", var.env]
}
