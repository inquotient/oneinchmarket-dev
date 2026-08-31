module "hetzner" {
  source = "./hetzner"
  count  = var.provider_name == "hetzner" ? 1 : 0

  worker_count = var.worker_count
  server_type  = local.hetzner_server_type
  location     = local.hetzner_location
  ssh_key      = var.ssh_public_key
  env          = var.env
}

module "vultr" {
  source = "./vultr"
  count  = var.provider_name == "vultr" ? 1 : 0

  worker_count              = var.worker_count
  bastion_plan              = var.bastion_plan
  master_plan               = local.vultr_master_plan
  worker_plan               = local.vultr_worker_plan
  region                    = local.vultr_region
  ssh_key                   = var.ssh_public_key
  env                       = var.env
  vpc_ids                   = var.vpc_ids
  bastion_firewall_group_id = var.bastion_firewall_group_id
  k3s_firewall_group_id     = var.k3s_firewall_group_id
}

locals {
  hetzner_server_type = lookup({
    "8-32"  = "ccx33"
    "16-64" = "ccx53"
    "4-16"  = "ccx23"
  }, "${var.worker_spec.cpu}-${var.worker_spec.memory}", "ccx33")

  vultr_worker_plan = lookup({
    "8-32"  = "vhf-8c-32gb"
    "16-64" = "vhf-16c-64gb"
    "4-16"  = "vhf-4c-16gb"
  }, "${var.worker_spec.cpu}-${var.worker_spec.memory}", "vhf-8c-32gb")

  vultr_master_plan = lookup({
    "8-32"  = "vhf-4c-16gb"
    "16-64" = "vhf-8c-32gb"
    "4-16"  = "vhf-2c-4gb"
  }, "${var.worker_spec.cpu}-${var.worker_spec.memory}", "vhf-4c-16gb")

  hetzner_location = lookup({
    "sin" = "sin"
    "sgp" = "sin"
    "fsn" = "fsn1"
  }, var.location, "sin")

  vultr_region = lookup({
    "sin" = "sgp"
    "sgp" = "sgp"
    "icn" = "icn"
    "kor" = "icn"
  }, var.location, "sgp")
}
