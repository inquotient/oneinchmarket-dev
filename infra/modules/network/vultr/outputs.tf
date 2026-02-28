output "network_id" {
  value = vultr_vpc.main.id
}

output "subnet_id" {
  value = vultr_vpc.main.id
}

output "firewall_group_id" {
  value = vultr_firewall_group.k3s.id
}
