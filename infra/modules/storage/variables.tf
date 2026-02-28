variable "provider_name" {
  type = string
}

variable "env" {
  type    = string
  default = "dev"
}

variable "volume_size" {
  type        = number
  default     = 100
  description = "Volume size in GB"
}

variable "worker_ids" {
  type        = list(string)
  description = "IDs of worker servers to attach volumes to"
}

variable "location" {
  type = string
}
