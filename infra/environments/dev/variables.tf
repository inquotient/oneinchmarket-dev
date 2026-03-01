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

variable "bastion_plan" {
  type    = string
  default = "vc2-1c-1gb"
}

variable "location" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "env" {
  type    = string
  default = "dev"
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

# Provider API keys - 환경변수로 설정 (TF_VAR_vultr_api_key, TF_VAR_hcloud_token 등)
variable "vultr_api_key" {
  type      = string
  default   = ""
  sensitive = true
}

variable "hcloud_token" {
  type      = string
  default   = ""
  sensitive = true
}

variable "hetzner_dns_token" {
  type      = string
  default   = ""
  sensitive = true
}
