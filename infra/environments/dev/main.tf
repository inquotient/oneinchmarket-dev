terraform {
  required_version = ">= 1.6.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
    hetznerdns = {
      source  = "timohirt/hetznerdns"
      version = "~> 2.2"
    }
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.19"
    }
  }
}

# 비활성 프로바이더도 초기화 필요 (count=0 모듈이라도 프로바이더 설정 요구)
# 실제 사용하는 프로바이더만 환경변수로 API 키 설정하면 됨
provider "hcloud" {
  token = var.provider_name == "hetzner" ? var.hcloud_token : "0000000000000000000000000000000000000000000000000000000000000000"
}

provider "hetznerdns" {
  apitoken = var.provider_name == "hetzner" ? var.hetzner_dns_token : "unused"
}

provider "vultr" {
  api_key = var.provider_name == "vultr" ? var.vultr_api_key : "unused"
}

module "compute" {
  source = "../../modules/compute"

  depends_on = [module.network]

  provider_name             = var.provider_name
  worker_count              = var.worker_count
  worker_spec               = var.worker_spec
  bastion_plan              = var.bastion_plan
  location                  = var.location
  ssh_public_key            = var.ssh_public_key
  env                       = var.env
  vpc_ids                   = var.provider_name == "vultr" ? [module.network.network_id] : []
  bastion_firewall_group_id = module.network.bastion_firewall_group_id
  k3s_firewall_group_id     = module.network.k3s_firewall_group_id
}

module "network" {
  source = "../../modules/network"

  provider_name = var.provider_name
  env           = var.env
  network_cidr  = var.network_cidr
  subnet_cidr   = var.subnet_cidr
  location      = var.location
}

module "dns" {
  source = "../../modules/dns"

  provider_name = var.provider_name
  domain        = var.domain
  env           = var.env
  ingress_ip    = module.compute.master_private_ip  # VPN 전용: VPC 사설 IP
}

output "bastion_ip" {
  value = module.compute.bastion_ip
}

output "master_ip" {
  value = module.compute.master_ip
}

output "master_private_ip" {
  value = module.compute.master_private_ip
}

output "worker_ips" {
  value = module.compute.worker_ips
}

output "worker_private_ips" {
  value = module.compute.worker_private_ips
}

output "network_id" {
  value = module.network.network_id
}
