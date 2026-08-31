variable "provider_name" {
  type        = string
  description = "Cloud provider: hetzner or vultr"
  validation {
    condition     = contains(["hetzner", "vultr"], var.provider_name)
    error_message = "Supported providers: hetzner, vultr"
  }
}

variable "worker_count" {
  type    = number
  default = 4
}

variable "worker_spec" {
  type = object({
    cpu    = number
    memory = number
  })
  default = { cpu = 8, memory = 32 }
}

variable "bastion_plan" {
  type        = string
  default     = "vc2-1c-1gb"
  description = "Vultr plan for bastion (WireGuard VPN only)"
}

variable "location" {
  type        = string
  description = "Region identifier (sin, sgp, icn, kor, fsn, etc.)"
}

variable "ssh_public_key" {
  type = string
}

variable "env" {
  type    = string
  default = "dev"
}

variable "vpc_ids" {
  type    = list(string)
  default = []
}

variable "bastion_firewall_group_id" {
  type    = string
  default = ""
}

variable "k3s_firewall_group_id" {
  type    = string
  default = ""
}
