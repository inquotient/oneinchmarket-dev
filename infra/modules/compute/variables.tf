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

variable "location" {
  type        = string
  description = "Region identifier (sin, sgp, icn, fsn, etc.)"
}

variable "ssh_public_key" {
  type = string
}

variable "env" {
  type    = string
  default = "dev"
}
