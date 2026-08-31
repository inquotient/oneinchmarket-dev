output "bastion_ip" {
  value = vultr_instance.bastion.main_ip
}

output "bastion_private_ip" {
  value = vultr_instance.bastion.internal_ip
}

output "master_ip" {
  value = vultr_instance.master.main_ip
}

output "master_private_ip" {
  value = vultr_instance.master.internal_ip
}

output "worker_ips" {
  value = vultr_instance.worker[*].main_ip
}

output "worker_private_ips" {
  value = vultr_instance.worker[*].internal_ip
}
