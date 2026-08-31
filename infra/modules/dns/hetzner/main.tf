terraform {
  required_providers {
    hetznerdns = {
      source  = "timohirt/hetznerdns"
      version = "~> 2.2"
    }
  }
}

data "hetznerdns_zone" "main" {
  name = var.domain
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

resource "hetznerdns_record" "wildcard" {
  zone_id = data.hetznerdns_zone.main.id
  name    = var.env == "prod" ? "*" : "*.${var.env}"
  value   = var.ingress_ip
  type    = "A"
  ttl     = 300
}

resource "hetznerdns_record" "services" {
  for_each = toset(local.subdomains)

  zone_id = data.hetznerdns_zone.main.id
  name    = var.env == "prod" ? each.key : "${each.key}.${var.env}"
  value   = var.ingress_ip
  type    = "A"
  ttl     = 300
}
