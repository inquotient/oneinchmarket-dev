module "hetzner" {
  source = "./hetzner"
  count  = var.provider_name == "hetzner" ? 1 : 0

  domain     = var.domain
  env        = var.env
  ingress_ip = var.ingress_ip
}

module "vultr" {
  source = "./vultr"
  count  = var.provider_name == "vultr" ? 1 : 0

  domain     = var.domain
  env        = var.env
  ingress_ip = var.ingress_ip
}
