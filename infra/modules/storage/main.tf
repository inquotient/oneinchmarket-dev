module "hetzner" {
  source = "./hetzner"
  count  = var.provider_name == "hetzner" ? 1 : 0

  env         = var.env
  volume_size = var.volume_size
  server_ids  = var.worker_ids
  location    = var.location
}

module "vultr" {
  source = "./vultr"
  count  = var.provider_name == "vultr" ? 1 : 0

  env          = var.env
  volume_size  = var.volume_size
  instance_ids = var.worker_ids
  region       = var.location
}
