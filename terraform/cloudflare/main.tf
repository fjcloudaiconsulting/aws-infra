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

# Auth: CLOUDFLARE_API_TOKEN, a sensitive env var on the TFC workspace. Account-scoped
# token with Zone:Edit, DNS:Edit and Zone Settings:Edit; a zone-scoped token cannot create
# the zone and only fails at apply.
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

# Baseline security for zones that serve apps (INFRA-14). Zone settings act only on proxied
# hostnames: ziftbook.com is proxied today, thebetterdecision.com picks them up when `app` is
# proxied at the Lightsail cutover. ziftbook.com's zone is read here, not managed.
data "cloudflare_zone" "ziftbook" {
  filter = { name = "ziftbook.com", account = { id = var.account_id } }
}

locals {
  app_zones = {
    tbd      = cloudflare_zone.tbd.id
    ziftbook = data.cloudflare_zone.ziftbook.id
  }
  app_zone_settings = {
    min_tls_version  = "1.2"
    always_use_https = "on"
    # HSTS without includeSubDomains or preload, so a host that cannot do HTTPS stays reachable
    # and backing out is max_age = 0 (browsers keep the old max_age until they revisit).
    # One year (INFRA-75): the zone header overrides the ziftbook landing worker's, whose smoke expects it.
    security_header = {
      strict_transport_security = {
        enabled            = true
        max_age            = 31536000
        include_subdomains = false
        preload            = false
        nosniff            = false
      }
    }
  }
}

# Removing an entry only drops it from state (the provider's Delete is a no-op), so back out by
# applying the old value ("off", max_age = 0), never by deleting it.
resource "cloudflare_zone_setting" "app" {
  for_each = {
    for pair in setproduct(keys(local.app_zones), keys(local.app_zone_settings)) :
    "${pair[0]}/${pair[1]}" => { zone = pair[0], setting = pair[1] }
  }

  zone_id    = local.app_zones[each.value.zone]
  setting_id = each.value.setting
  value      = local.app_zone_settings[each.value.setting]
}

# The k3s node behind Cloudflare (INFRA-25). Traefik serves a Cloudflare Origin CA certificate (since INFRA-47 it should cover both zones, see docs/configuration-map.md)
# for thebetterdecision.com and *.thebetterdecision.com, so this zone runs in Full (strict).
# Safe to flip now: no other record in the zone is proxied, and a DNS-only record never
# reaches this setting. The zone's SSL/TLS mode is already Custom (ssl_automatic_mode =
# custom, read 2026-10-02), so this value does not drift. Until origin-cert.secret.yaml is in
# the cluster, ping below answers 526 under strict; merge only with the secret files in.
# ziftbook.com moved to strict with its first proxied hostname on the node (INFRA-47, below).
resource "cloudflare_zone_setting" "tbd_ssl" {
  zone_id    = cloudflare_zone.tbd.id
  setting_id = "ssl"
  value      = "strict"
}

# Traefik answers /ping here itself: the end-to-end check through Cloudflare to the node, and
# the target of the external uptime check (INFRA-26). Content is the platform workspace's
# node_static_ip output.
resource "cloudflare_dns_record" "tbd_ping" {
  zone_id = cloudflare_zone.tbd.id
  name    = "ping.thebetterdecision.com"
  type    = "A"
  content = "52.57.109.122"
  ttl     = 1 # automatic, required for proxied records
  proxied = true
}

# Ziftbook staging (INFRA-47), hostname per the 2026-10-03 ruling (staging = dev.<domain>). Under
# strict, Traefik must serve an Origin CA cert that covers ziftbook.com, or this host answers 526
# (the apex and www are a Worker and do not use the origin). Same node IP as ping above.
# The zone was read 2026-10-03 as ssl = full, ssl_automatic_mode = auto: auto re-scans and could move the mode
# back, so it is pinned to custom first. Merge the origin-cert secret before approving this apply.
resource "cloudflare_dns_record" "ziftbook_dev" {
  zone_id = data.cloudflare_zone.ziftbook.id
  name    = "dev.ziftbook.com"
  type    = "A"
  content = "52.57.109.122"
  ttl     = 1 # automatic, required for proxied records
  proxied = true
}

resource "cloudflare_zone_setting" "ziftbook_ssl_mode" {
  zone_id    = data.cloudflare_zone.ziftbook.id
  setting_id = "ssl_automatic_mode"
  value      = "custom"
}

resource "cloudflare_zone_setting" "ziftbook_ssl" {
  zone_id    = data.cloudflare_zone.ziftbook.id
  setting_id = "ssl"
  value      = "strict"

  depends_on = [cloudflare_zone_setting.ziftbook_ssl_mode]
}

# Mailgun sending domain for Ziftbook staging (INFRA-47): TBD's naming (m.<host>, EU region), so
# m.dev.ziftbook.com. MX, SPF and tracking are fixed by Mailgun's EU endpoints. The DKIM TXT is
# generated by Mailgun when the owner adds the domain: step two is setting ziftbook_dev_dkim below to
# { name = "<selector>._domainkey.m.dev.ziftbook.com", content = "\"k=rsa; p=...\"" } in a follow-up
# commit (a public key, not a secret). Until then Mailgun cannot verify the domain.
locals {
  ziftbook_dev_dkim = null

  ziftbook_dev_mail_records = merge(
    {
      mx_a     = { type = "MX", name = "m.dev.ziftbook.com", content = "mxa.eu.mailgun.org", priority = 10 }
      mx_b     = { type = "MX", name = "m.dev.ziftbook.com", content = "mxb.eu.mailgun.org", priority = 10 }
      spf      = { type = "TXT", name = "m.dev.ziftbook.com", content = "\"v=spf1 include:mailgun.org ~all\"" }
      tracking = { type = "CNAME", name = "email.m.dev.ziftbook.com", content = "eu.mailgun.org" }
    },
    local.ziftbook_dev_dkim == null ? {} : { dkim = merge({ type = "TXT" }, local.ziftbook_dev_dkim) }
  )
}

resource "cloudflare_dns_record" "ziftbook_dev_mail" {
  for_each = local.ziftbook_dev_mail_records

  zone_id  = data.cloudflare_zone.ziftbook.id
  name     = each.value.name
  type     = each.value.type
  content  = each.value.content
  priority = try(each.value.priority, null)
  ttl      = 300
  proxied  = false
}

output "tbd_name_servers" {
  description = "Set these at the registrar (Route 53 Domains, old AWS account) to switch DNS to Cloudflare."
  value       = cloudflare_zone.tbd.name_servers
}

output "tbd_zone_status" {
  description = "pending until the registrar NS switch, then active."
  value       = cloudflare_zone.tbd.status
}
