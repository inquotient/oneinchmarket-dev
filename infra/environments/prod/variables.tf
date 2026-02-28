variable "provider_name" {
  type = string
}

variable "worker_count" {
  type    = number
  default = 5
}

variable "worker_spec" {
  type = object({
    cpu    = number
    memory = number
  })
  default = { cpu = 8, memory = 32 }
}

variable "location" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "env" {
  type    = string
  default = "prod"
}

variable "domain" {
  type    = string
  default = "oneinchmarket.co.kr"
}

variable "network_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "volume_size" {
  type    = number
  default = 200
}
