output "worker_ips" {
  value = hcloud_server.worker[*].ipv4_address
}

output "private_ips" {
  value = hcloud_server.worker[*].ipv4_address
}

output "bastion_ip" {
  value = hcloud_server.worker[0].ipv4_address
}
