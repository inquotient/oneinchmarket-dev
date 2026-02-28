output "volume_ids" {
  value = var.provider_name == "hetzner" ? module.hetzner[0].volume_ids : module.vultr[0].volume_ids
}
