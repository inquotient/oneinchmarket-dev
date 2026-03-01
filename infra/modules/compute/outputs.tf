output "bastion_ip" {
  description = "Public IP of bastion node"
  value       = var.provider_name == "hetzner" ? module.hetzner[0].bastion_ip : module.vultr[0].bastion_ip
}

output "bastion_private_ip" {
  description = "VPC private IP of bastion node"
  value       = var.provider_name == "vultr" ? module.vultr[0].bastion_private_ip : ""
}

output "master_ip" {
  description = "Public IP of master node"
  value       = var.provider_name == "vultr" ? module.vultr[0].master_ip : ""
}

output "master_private_ip" {
  description = "VPC private IP of master node"
  value       = var.provider_name == "vultr" ? module.vultr[0].master_private_ip : ""
}

output "worker_ips" {
  description = "Public IPs of worker nodes"
  value       = var.provider_name == "hetzner" ? module.hetzner[0].worker_ips : module.vultr[0].worker_ips
}

output "worker_private_ips" {
  description = "VPC private IPs of worker nodes"
  value       = var.provider_name == "hetzner" ? module.hetzner[0].private_ips : module.vultr[0].worker_private_ips
}
