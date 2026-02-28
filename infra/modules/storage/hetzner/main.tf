terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }
}

resource "hcloud_volume" "data" {
  count    = length(var.server_ids)
  name     = "${var.env}-data-${count.index + 1}"
  size     = var.volume_size
  location = var.location
  format   = "ext4"
}

resource "hcloud_volume_attachment" "data" {
  count     = length(var.server_ids)
  volume_id = hcloud_volume.data[count.index].id
  server_id = var.server_ids[count.index]
  automount = true
}
