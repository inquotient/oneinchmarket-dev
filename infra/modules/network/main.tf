module "hetzner" {
  source = "./hetzner"
  count  = var.provider_name == "hetzner" ? 1 : 0

  env          = var.env
  network_cidr = var.network_cidr
  subnet_cidr  = var.subnet_cidr
  location     = var.location
}

module "vultr" {
  source = "./vultr"
  count  = var.provider_name == "vultr" ? 1 : 0

  env          = var.env
  network_cidr = var.network_cidr
  subnet_cidr  = var.subnet_cidr
  region       = var.location
}
