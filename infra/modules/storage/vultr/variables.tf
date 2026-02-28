variable "env" {
  type = string
}

variable "volume_size" {
  type = number
}

variable "instance_ids" {
  type = list(string)
}

variable "region" {
  type = string
}
