output "volume_ids" {
  value = hcloud_volume.data[*].id
}
