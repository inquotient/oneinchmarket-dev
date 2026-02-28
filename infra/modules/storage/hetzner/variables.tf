variable "env" {
  type = string
}

variable "volume_size" {
  type = number
}

variable "server_ids" {
  type = list(string)
}

variable "location" {
  type = string
}
