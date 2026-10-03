# Zone-level Authenticated Origin Pulls (INFRA-93). The node's firewall admits any Cloudflare IP, so any
# Cloudflare zone, including someone else's, can point a record at it. With this on, Cloudflare presents our
# own client certificate when it connects to the origin for these zones, and Traefik rejects every TLS client
# that does not show a certificate signed by our CA (clusters/platform/traefik). Not global AOP: its
# certificate is shared by every Cloudflare account.
#
# One leaf for both zones: Traefik trusts the CA, not a zone, so a leaf per zone would add a key and a rotation
# without narrowing what the origin accepts. The CA key is deleted after signing; rotation is a new CA and leaf,
# with Traefik trusting both during the swap (docs/runbooks.md, origin pull certificate).
#
# Both values are workspace variables created by the owner; the key is sensitive and never in git.
# The API token needs "SSL and Certificates: Edit" on both zones (Zone Settings does not cover these endpoints).
variable "origin_pull_certificate" {
  description = "PEM leaf certificate Cloudflare presents to the origin (public)."
  type        = string
}

variable "origin_pull_private_key" {
  description = "PEM private key of origin_pull_certificate."
  type        = string
  sensitive   = true
}

# A new certificate replaces the resource; create_before_destroy uploads the new one before the old is deleted,
# so the zone is never without one.
resource "cloudflare_authenticated_origin_pulls_certificate" "app" {
  for_each = local.app_zones

  zone_id     = each.value
  certificate = var.origin_pull_certificate
  private_key = var.origin_pull_private_key

  lifecycle {
    create_before_destroy = true
  }
}

# Harmless until Traefik requires the certificate: the origin does not ask for one yet. Removing this resource
# only drops it from state (the provider's Delete is a no-op), so back out with enabled = false.
resource "cloudflare_authenticated_origin_pulls_settings" "app" {
  for_each = local.app_zones

  zone_id = each.value
  enabled = true

  depends_on = [cloudflare_authenticated_origin_pulls_certificate.app]
}

output "origin_pull_certificates" {
  description = "Per zone: status (must be active before Traefik requires the certificate), issuer and expiry."
  value = {
    for zone, c in cloudflare_authenticated_origin_pulls_certificate.app :
    zone => { status = c.status, issuer = c.issuer, expires_on = c.expires_on }
  }
}
