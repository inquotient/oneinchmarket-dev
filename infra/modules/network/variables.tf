variable "provider_name" {
  type        = string
  description = "Cloud provider: hetzner or vultr"
}

variable "env" {
  type    = string
  default = "dev"
}

variable "network_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "location" {
  type = string
}
