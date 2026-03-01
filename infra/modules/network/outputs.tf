output "network_id" {
  value = var.provider_name == "hetzner" ? module.hetzner[0].network_id : module.vultr[0].network_id
}

output "subnet_id" {
  value = var.provider_name == "hetzner" ? module.hetzner[0].subnet_id : module.vultr[0].subnet_id
}

output "bastion_firewall_group_id" {
  value = var.provider_name == "vultr" ? module.vultr[0].bastion_firewall_group_id : ""
}

output "k3s_firewall_group_id" {
  value = var.provider_name == "vultr" ? module.vultr[0].k3s_firewall_group_id : ""
}
