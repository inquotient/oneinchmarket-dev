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

  worker_count = var.worker_count
  plan         = local.vultr_plan
  region       = local.vultr_region
  ssh_key      = var.ssh_public_key
  env          = var.env
}

locals {
  hetzner_server_type = lookup({
    "8-32"  = "ccx33"
    "16-64" = "ccx53"
    "4-16"  = "ccx23"
  }, "${var.worker_spec.cpu}-${var.worker_spec.memory}", "ccx33")

  vultr_plan = lookup({
    "8-32"  = "vhp-8c-32gb-amd"
    "16-64" = "vhp-16c-64gb-amd"
    "4-16"  = "vhp-4c-16gb-amd"
  }, "${var.worker_spec.cpu}-${var.worker_spec.memory}", "vhp-8c-32gb-amd")

  hetzner_location = lookup({
    "sin" = "sin"
    "sgp" = "sin"
    "fsn" = "fsn1"
  }, var.location, "sin")

  vultr_region = lookup({
    "sin" = "sgp"
    "sgp" = "sgp"
    "icn" = "icn"
  }, var.location, "sgp")
}
