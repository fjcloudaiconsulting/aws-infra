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

# Auth: CLOUDFLARE_API_TOKEN, a sensitive env var on the TFC workspace. It must also cover zone
# fjconsulting.dev (read for the shared dev Mailgun records, INFRA-47). Account-scoped
# token with Zone:Edit, DNS:Edit and Zone Settings:Edit; a zone-scoped token cannot create the zone and
# only fails at apply. Origin pulls (INFRA-93) add a separate policy, SSL and Certificates:Edit on
# thebetterdecision.com and ziftbook.com only, and Account Notifications:Edit.
provider "cloudflare" {}

variable "account_id" {
  description = "Cloudflare account that owns the zones."
  type        = string
}

# thebetterdecision.com moves here from Route 53 in the old AWS account (INFRA-15).
# Every record below is a 1:1 copy of the Route 53 export taken 2026-10-01 and DNS-only
# (proxied = false), except `app`, proxied to the k3s node since the cutover (INFRA-48), and `www` (INFRA-61).
# The apex is the Worker `tbd-landing` since INFRA-61: a custom domain attached by hand, whose own read-only
# record is not managed here (docs/configuration-map.md, Worker and Snippet access).
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
    # www: proxied only so the redirect rule below (tbd_www) can answer it; Cloudflare never fetches this target.
    # It stays the CloudFront name so the change is in place, and if the rule is ever off CloudFront still sends
    # its own 301 to the apex. INFRA-62 must retarget it before deleting the distribution.
    www = { name = "www.thebetterdecision.com", type = "CNAME", content = "d1vhzkck8shsp8.cloudfront.net", ttl = 1, proxied = true }

    google_verification = { name = "thebetterdecision.com", type = "TXT", content = "\"google-site-verification=n5V8oSnk53Vi4UraYvoNiWv6FrBVeYkSGDAD9VsMTPY\"", ttl = 60 }

    # TBD on the k3s node (INFRA-48): proxied, so clients see Cloudflare and Cloudflare reaches the node through
    # ping's address (node_static_ip, kept in one record). Staying a CNAME keeps this an in-place update; the
    # rollback (revert) is one too, back to DNS-only `pfv-xccvs.ondigitalocean.app` with ttl 60.
    app = { name = "app.thebetterdecision.com", type = "CNAME", content = "ping.thebetterdecision.com", ttl = 1, proxied = true }

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
  proxied  = try(each.value.proxied, false)
}

# www -> apex, 301, path and query kept (INFRA-61; CloudFront did the same). A zone rule rather than Worker code: the
# Worker would have to run first on every request (run_worker_first) to see the host, and every asset hit would then
# count against the Free plan's Worker requests. Free allows 10 such rules per zone. A rule added in the dashboard is
# drift that the next apply removes. The workspace token needs Zone > Single Redirect > Edit on this zone.
resource "cloudflare_ruleset" "tbd_redirects" {
  zone_id = cloudflare_zone.tbd.id
  name    = "default"
  kind    = "zone"
  phase   = "http_request_dynamic_redirect"

  rules = [{
    ref         = "www_to_apex"
    description = "www to the apex, 301, keeps path and query (INFRA-61)"
    expression  = "(http.host eq \"www.thebetterdecision.com\")"
    action      = "redirect"
    enabled     = true
    action_parameters = {
      from_value = {
        status_code           = 301
        preserve_query_string = true
        target_url = {
          expression = "concat(\"https://thebetterdecision.com\", http.request.uri.path)"
        }
      }
    }
  }]
}

# Baseline security for zones that serve apps (INFRA-14). Zone settings act only on proxied
# hostnames: ziftbook.com (dev, apex and www), thebetterdecision.com (ping, `app` since the INFRA-48 cutover, apex and
# www since INFRA-61).
# ziftbook.com's zone is read here, not managed.
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
    # One year (INFRA-75): the zone header overrides the landing Workers' own (ziftbook's smoke expects it). On the TBD
    # apex it replaces the two years with includeSubDomains and preload that CloudFront sent (INFRA-61).
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
# node_static_ip output. `app` is a CNAME to this record: changing it moves TBD production too.
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

# Shared Mailgun sending domain for every dev/staging environment (INFRA-47, owner ruling 2026-10-03):
# m.fjconsulting.dev, EU region. Only production gets per-app m.<appdomain> domains. The zone is
# read, not managed: its other records (Google mail, site) live outside Terraform. The record set
# mirrors TBD's m.thebetterdecision.com above (MX, SPF, DKIM, DMARC with Mailgun reporting, tracking).
# Mailgun's Cloudflare auto-setup created all but the MX on 2026-10-03; they were adopted with import
# blocks, removed once applied. A second dev app only needs a new Mailgun sending key, no change
# here. The DKIM value is a public key, split in two strings (TXT 255-char limit).
data "cloudflare_zone" "fjdev" {
  filter = { name = "fjconsulting.dev", account = { id = var.account_id } }
}

locals {
  fjdev_mail_records = {
    mx_a     = { type = "MX", name = "m.fjconsulting.dev", content = "mxa.eu.mailgun.org", priority = 10 }
    mx_b     = { type = "MX", name = "m.fjconsulting.dev", content = "mxb.eu.mailgun.org", priority = 10 }
    spf      = { type = "TXT", name = "m.fjconsulting.dev", content = "\"v=spf1 include:mailgun.org ~all\"" }
    dmarc    = { type = "TXT", name = "_dmarc.m.fjconsulting.dev", content = "\"v=DMARC1; p=none; pct=100; fo=1; ri=3600; rua=mailto:ebe10ff8@dmarc.mailgun.org,mailto:e05f9325@inbox.ondmarc.com; ruf=mailto:ebe10ff8@dmarc.mailgun.org,mailto:e05f9325@inbox.ondmarc.com;\"" }
    dkim     = { type = "TXT", name = "mta._domainkey.m.fjconsulting.dev", content = "\"k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEApsCPgZz8EKnXqDFkGDP2gBc1qxfcyT3zD18o+I7HaGzq4zV4Ib76F6vOFPJjrxwBya74NdLXp+vClblG75xFcVAMkg17RPVu0kIJ+9SNWox2H2cVs1P4s2WL3a22uVoZnod/ORjtpYUT99xKbsjYM89i7byAJiwHG5TDtevNxtjws1ZgwVJcCNbJg58LEq9VxpLIR+26ft\" \"r7Y2z5mSNQuZ0erEDYGpuLaVehCIX81XqqpPpl51VDpE+/ZYZ1UINGzc1BxeEKu4w/HT1dloRwx9ebkwnjA3IK0r1tfhffO6uaxjKc0CCpCZKnCuvuhwiF4cKemLiF/SMBP7joNZPH7QIDAQAB\"" }
    tracking = { type = "CNAME", name = "email.m.fjconsulting.dev", content = "eu.mailgun.org" }
  }
}

resource "cloudflare_dns_record" "fjdev_mail" {
  for_each = local.fjdev_mail_records

  zone_id  = data.cloudflare_zone.fjdev.id
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
