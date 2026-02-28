terraform {
  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.19"
    }
  }
}

resource "vultr_dns_domain" "main" {
  domain = var.domain
}

locals {
  subdomains = [
    "gitlab",
    "argocd",
    "keycloak",
    "kafka-ui",
    "kibana",
    "minio",
    "admin",
  ]
}

resource "vultr_dns_record" "wildcard" {
  domain = vultr_dns_domain.main.id
  name   = var.env == "prod" ? "*" : "*.${var.env}"
  data   = var.ingress_ip
  type   = "A"
  ttl    = 300
}

resource "vultr_dns_record" "services" {
  for_each = toset(local.subdomains)

  domain = vultr_dns_domain.main.id
  name   = var.env == "prod" ? each.key : "${each.key}.${var.env}"
  data   = var.ingress_ip
  type   = "A"
  ttl    = 300
}
