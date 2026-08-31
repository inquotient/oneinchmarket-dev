output "network_id" {
  value = hcloud_network.main.id
}

output "subnet_id" {
  value = hcloud_network_subnet.k3s.id
}

output "firewall_id" {
  value = hcloud_firewall.k3s.id
}
