output "worker_ips" {
  description = "Public IPs of worker nodes"
  value       = var.provider_name == "hetzner" ? module.hetzner[0].worker_ips : module.vultr[0].worker_ips
}

output "worker_private_ips" {
  description = "Private IPs of worker nodes"
  value       = var.provider_name == "hetzner" ? module.hetzner[0].private_ips : module.vultr[0].private_ips
}

output "bastion_ip" {
  description = "Public IP of bastion/first node"
  value       = var.provider_name == "hetzner" ? module.hetzner[0].bastion_ip : module.vultr[0].bastion_ip
}
