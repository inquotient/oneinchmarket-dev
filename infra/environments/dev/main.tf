terraform {
  required_version = ">= 1.6.0"
}

module "compute" {
  source = "../../modules/compute"

  provider_name  = var.provider_name
  worker_count   = var.worker_count
  worker_spec    = var.worker_spec
  location       = var.location
  ssh_public_key = var.ssh_public_key
  env            = var.env
}

module "network" {
  source = "../../modules/network"

  provider_name = var.provider_name
  env           = var.env
  network_cidr  = var.network_cidr
  subnet_cidr   = var.subnet_cidr
  location      = var.location
}

module "dns" {
  source = "../../modules/dns"

  provider_name = var.provider_name
  domain        = var.domain
  env           = var.env
  ingress_ip    = module.compute.bastion_ip
}

output "worker_ips" {
  value = module.compute.worker_ips
}

output "bastion_ip" {
  value = module.compute.bastion_ip
}

output "network_id" {
  value = module.network.network_id
}
