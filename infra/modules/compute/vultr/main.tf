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

resource "vultr_instance" "bastion" {
  label             = "${var.env}-bastion"
  plan              = var.bastion_plan
  region            = var.region
  os_id             = 2284 # Ubuntu 24.04
  ssh_key_ids       = [vultr_ssh_key.deploy.id]
  vpc_ids           = var.vpc_ids
  firewall_group_id = var.bastion_firewall_group_id

  tags = ["bastion", var.env]
}

resource "vultr_instance" "master" {
  label             = "${var.env}-master"
  plan              = var.master_plan
  region            = var.region
  os_id             = 2284 # Ubuntu 24.04
  ssh_key_ids       = [vultr_ssh_key.deploy.id]
  vpc_ids           = var.vpc_ids
  firewall_group_id = var.k3s_firewall_group_id

  tags = ["master", var.env]
}

resource "vultr_instance" "worker" {
  count             = var.worker_count
  label             = "${var.env}-worker-${count.index + 1}"
  plan              = var.worker_plan
  region            = var.region
  os_id             = 2284 # Ubuntu 24.04
  ssh_key_ids       = [vultr_ssh_key.deploy.id]
  vpc_ids           = var.vpc_ids
  firewall_group_id = var.k3s_firewall_group_id

  tags = ["worker", var.env]
}
