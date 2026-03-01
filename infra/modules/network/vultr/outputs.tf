output "network_id" {
  value = vultr_vpc.main.id
}

output "subnet_id" {
  value = vultr_vpc.main.id
}

output "bastion_firewall_group_id" {
  value = vultr_firewall_group.bastion.id
}

output "k3s_firewall_group_id" {
  value = vultr_firewall_group.k3s.id
}
