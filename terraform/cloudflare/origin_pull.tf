# Zone-level Authenticated Origin Pulls (INFRA-93). The node's firewall admits any Cloudflare IP, so any
# Cloudflare zone, including someone else's, can point a record at it. With this on, Cloudflare presents our
# own client certificate when it connects to the origin for these zones, and Traefik rejects every TLS client
# that does not show a certificate signed by our CA (clusters/platform/traefik). Not global AOP: its
# certificate is shared by every Cloudflare account.
#
# One leaf for both zones: Traefik trusts the CA, not a zone, so a leaf per zone would add a key and a rotation
# without narrowing what the origin accepts. The CA key is discarded after signing.
#
# Certificates come in generations. Each has its public leaf in origin-pull/<gen>.crt and its key in a sensitive
# workspace variable origin_pull_private_key_<gen>, created by the owner and never in git (it also lands in this
# workspace's state, so remote state sharing stays off). Rotation (docs/runbooks.md): add generation N+1, apply,
# wait for Active (with two active, Cloudflare uses the most recently deployed), then remove N and apply again.
# The API token needs "SSL and Certificates: Edit" on both zones and "Notifications: Edit" on the account.
variable "origin_pull_private_key_1" {
  description = "PEM private key of origin-pull/1.crt."
  type        = string
  sensitive   = true
}

locals {
  origin_pull_keys = {
    "1" = var.origin_pull_private_key_1
  }
  # A generation is uploaded only once its certificate is committed.
  origin_pull_certs = {
    for gen in keys(local.origin_pull_keys) : gen => file("${path.module}/origin-pull/${gen}.crt")
    if fileexists("${path.module}/origin-pull/${gen}.crt")
  }
}

# The provider replaces this resource on any certificate change and its Update does nothing, so never edit a
# generation in place: add a new one.
resource "cloudflare_authenticated_origin_pulls_certificate" "app" {
  for_each = {
    for pair in setproduct(keys(local.app_zones), keys(local.origin_pull_certs)) :
    "${pair[0]}/${pair[1]}" => { zone = pair[0], gen = pair[1] }
  }

  zone_id     = local.app_zones[each.value.zone]
  certificate = local.origin_pull_certs[each.value.gen]
  private_key = local.origin_pull_keys[each.value.gen]
}

# Harmless until Traefik requires the certificate: the origin does not ask for one yet. Removing this resource
# only drops it from state (the provider's Delete is a no-op), so back out by applying enabled = false.
resource "cloudflare_authenticated_origin_pulls_settings" "app" {
  for_each = local.app_zones

  zone_id = each.value
  enabled = length(local.origin_pull_certs) > 0

  depends_on = [cloudflare_authenticated_origin_pulls_certificate.app]
}

# Cloudflare emails 30 and 14 days before a zone-level AOP certificate expires. The alert type has no zone filter,
# so this one policy covers both zones.
resource "cloudflare_notification_policy" "origin_pull_expiry" {
  account_id  = var.account_id
  name        = "Origin pull certificate expiring (INFRA-93)"
  description = "Zone-level Authenticated Origin Pulls certificate expires within 30 days. Rotate per docs/runbooks.md in aws-infra."
  alert_type  = "zone_aop_custom_certificate_expiration_type"
  mechanisms  = { email = [{ id = "flamarion@fjconsulting.io" }] }
}

output "origin_pull_certificates" {
  description = "Per zone/generation: issuer and expiry, and status as of the last run (not a gate: check Active in the dashboard)."
  value = {
    for k, c in cloudflare_authenticated_origin_pulls_certificate.app :
    k => { status = c.status, issuer = c.issuer, expires_on = c.expires_on }
  }
}
