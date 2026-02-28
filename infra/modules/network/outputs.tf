output "network_id" {
  value = var.provider_name == "hetzner" ? module.hetzner[0].network_id : module.vultr[0].network_id
}

output "subnet_id" {
  value = var.provider_name == "hetzner" ? module.hetzner[0].subnet_id : module.vultr[0].subnet_id
}
