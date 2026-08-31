output "volume_ids" {
  value = vultr_block_storage.data[*].id
}
