terraform {
  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.19"
    }
  }
}

resource "vultr_block_storage" "data" {
  count             = length(var.instance_ids)
  label             = "${var.env}-data-${count.index + 1}"
  size_gb           = var.volume_size
  region            = var.region
  attached_to_instance = var.instance_ids[count.index]
  live              = true
}
