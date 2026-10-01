terraform {
  required_version = "~> 1.16.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.26"
    }
  }

  cloud {
    organization = "FlamaCorp"
    workspaces {
      name = "cloudflare"
    }
  }
}

# Auth: CLOUDFLARE_API_TOKEN, a sensitive env var on the TFC workspace.
provider "cloudflare" {}

variable "account_id" {
  description = "Cloudflare account that owns the zones."
  type        = string
}

# thebetterdecision.com moves here from Route 53 in the old AWS account (INFRA-15).
# Every record below is a 1:1 copy of the Route 53 export taken 2026-10-01 and stays
# DNS-only (proxied = false), so the nameserver switch changes nothing for clients.
# Proxying `app` is a separate change at the Lightsail cutover.
resource "cloudflare_zone" "tbd" {
  account = { id = var.account_id }
  name    = "thebetterdecision.com"
  type    = "full"

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  tbd_records = {
    # Apex + www: Route 53 A/AAAA aliases to CloudFront become CNAMEs (flattened at the apex).
    apex = { name = "thebetterdecision.com", type = "CNAME", content = "d1vhzkck8shsp8.cloudfront.net", ttl = 300 }
    www  = { name = "www.thebetterdecision.com", type = "CNAME", content = "d1vhzkck8shsp8.cloudfront.net", ttl = 300 }

    google_verification = { name = "thebetterdecision.com", type = "TXT", content = "\"google-site-verification=n5V8oSnk53Vi4UraYvoNiWv6FrBVeYkSGDAD9VsMTPY\"", ttl = 60 }

    # App on DigitalOcean until the Lightsail cutover (INFRA-48).
    app = { name = "app.thebetterdecision.com", type = "CNAME", content = "pfv-xccvs.ondigitalocean.app", ttl = 60 }

    # ACM DNS validation for the apex CloudFront certificate (tbd-apex workspace, us-east-1).
    # Must keep resolving or ACM renewal fails.
    acm_apex = { name = "_d8193f70c4baeb1cabf4316aaa913106.thebetterdecision.com", type = "CNAME", content = "_419d9cb8ee524cbab9f96e9fa86ad7be.jkddzztszm.acm-validations.aws", ttl = 60 }
    acm_www  = { name = "_f5a90d945c9943f00f2a831d0daeadb8.www.thebetterdecision.com", type = "CNAME", content = "_0dacccdcbeeec26030fcfe050474b493.jkddzztszm.acm-validations.aws", ttl = 60 }

    # Mailgun sending domain m.thebetterdecision.com (EU).
    mailgun_mx_a     = { name = "m.thebetterdecision.com", type = "MX", content = "mxa.eu.mailgun.org", priority = 10, ttl = 300 }
    mailgun_mx_b     = { name = "m.thebetterdecision.com", type = "MX", content = "mxb.eu.mailgun.org", priority = 10, ttl = 300 }
    mailgun_spf      = { name = "m.thebetterdecision.com", type = "TXT", content = "\"v=spf1 include:mailgun.org ~all\"", ttl = 300 }
    mailgun_dmarc    = { name = "_dmarc.m.thebetterdecision.com", type = "TXT", content = "\"v=DMARC1; p=none; pct=100; fo=1; ri=3600; rua=mailto:ebe10ff8@dmarc.mailgun.org,mailto:e05f9325@inbox.ondmarc.com; ruf=mailto:ebe10ff8@dmarc.mailgun.org,mailto:e05f9325@inbox.ondmarc.com;\"", ttl = 300 }
    mailgun_dkim     = { name = "email._domainkey.m.thebetterdecision.com", type = "TXT", content = "\"k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDJBSffQ3yl09L0oEmhSxrnVL2YgZ/eUnWT4PEcsW7yzkasaxsNdKC/R9Rud5CyJ0Vc4Q7M7irRRO7N/ChRvO8zFF4jFEJ1pHTtnb7dii1W69ii3tXaaie2OIg3INfs/xPk2IROI1bfWZ61Zr5VU8X+M9qFmP6DG69RjFXLxjvAbwIDAQAB\"", ttl = 300 }
    mailgun_tracking = { name = "email.m.thebetterdecision.com", type = "CNAME", content = "eu.mailgun.org", ttl = 300 }
  }
}

resource "cloudflare_dns_record" "tbd" {
  for_each = local.tbd_records

  zone_id  = cloudflare_zone.tbd.id
  name     = each.value.name
  type     = each.value.type
  content  = each.value.content
  priority = try(each.value.priority, null)
  ttl      = each.value.ttl
  proxied  = false
}

output "tbd_name_servers" {
  description = "Set these at the registrar (Route 53 Domains, old AWS account) to switch DNS to Cloudflare."
  value       = cloudflare_zone.tbd.name_servers
}

output "tbd_zone_status" {
  value = cloudflare_zone.tbd.status
}
