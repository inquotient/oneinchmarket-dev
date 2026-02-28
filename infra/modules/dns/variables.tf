variable "provider_name" {
  type = string
}

variable "domain" {
  type        = string
  default     = "oneinchmarket.co.kr"
  description = "Base domain name"
}

variable "env" {
  type    = string
  default = "dev"
}

variable "ingress_ip" {
  type        = string
  description = "IP address for DNS A records"
}
