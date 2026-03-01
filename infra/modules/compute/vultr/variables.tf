variable "worker_count" {
  type = number
}

variable "bastion_plan" {
  type = string
}

variable "master_plan" {
  type = string
}

variable "worker_plan" {
  type = string
}

variable "region" {
  type = string
}

variable "ssh_key" {
  type = string
}

variable "env" {
  type = string
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
