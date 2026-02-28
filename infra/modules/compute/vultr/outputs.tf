output "worker_ips" {
  value = vultr_instance.worker[*].main_ip
}

output "private_ips" {
  value = vultr_instance.worker[*].internal_ip
}

output "bastion_ip" {
  value = vultr_instance.worker[0].main_ip
}
