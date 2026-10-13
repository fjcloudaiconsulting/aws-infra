# Zone-level Authenticated Origin Pulls (INFRA-93) guarded the Lightsail origin, now gone (INFRA-176); every app reaches
# Cloudflare through the Hetzner tunnel, which origin pulls do not apply to. The certificates are deleted, and the
# provider's delete would leave the zone toggle on, so it stays here as an explicit off. In state this depended on the
# certificates, so Terraform switches it off before it deletes them.
resource "cloudflare_authenticated_origin_pulls_settings" "app" {
  for_each = local.app_zones
  zone_id  = each.value
  enabled  = false
}
