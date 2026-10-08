# Cloudflare Access in front of TBD staging (INFRA-117): dev.thebetterdecision.com is reachable only after an email
# one-time PIN sent to the owner. Staging is not indexable either (a crawler gets the login redirect).
#
# Prerequisites (owner, once; docs/runbooks.md, "Cloudflare Access on staging"): Zero Trust enabled on the account (Free
# plan, team name chosen) and the One-time PIN login method on. The workspace token needs "Access: Apps and Policies
# Write" (cloudflare-tokens, INFRA-117): apply that workspace first.
#
# Bypass is exactly what the post-deploy smoke needs (.github/scripts/post-deploy-smoke.sh, tbd-staging): GET /health
# and GET /robots.txt (served by the frontend container). Access picks the most specific path, so the bypass
# applications win over the whole-host one. Everything else, /api included, needs the login: the frontend and its API
# share the host, so one login cookie covers both.

locals {
  access_host = "dev.thebetterdecision.com"
  access_allow_emails = [
    "flamarion@fjconsulting.io",
  ]
}

resource "cloudflare_zero_trust_access_policy" "tbd_staging_owner" {
  account_id       = var.account_id
  name             = "tbd-staging: owner (INFRA-117)"
  decision         = "allow"
  session_duration = "24h"

  include = [for e in local.access_allow_emails : { email = { email = e } }]
}

resource "cloudflare_zero_trust_access_policy" "tbd_staging_smoke_bypass" {
  account_id = var.account_id
  name       = "tbd-staging: smoke bypass, health and robots.txt (INFRA-117)"
  decision   = "bypass"

  include = [{ everyone = {} }]
}

resource "cloudflare_zero_trust_access_application" "tbd_staging" {
  account_id       = var.account_id
  name             = "tbd-staging"
  type             = "self_hosted"
  domain           = local.access_host
  session_duration = "24h"

  # Only the owner policy applies, so the owner's address gets a code by email (One-time PIN is the one login method).
  app_launcher_visible = false

  policies = [{ id = cloudflare_zero_trust_access_policy.tbd_staging_owner.id, precedence = 1 }]
}

resource "cloudflare_zero_trust_access_application" "tbd_staging_smoke" {
  for_each = toset(["/health", "/robots.txt"])

  account_id           = var.account_id
  name                 = "tbd-staging smoke bypass ${each.key}"
  type                 = "self_hosted"
  domain               = "${local.access_host}${each.key}"
  session_duration     = "24h"
  app_launcher_visible = false

  policies = [{ id = cloudflare_zero_trust_access_policy.tbd_staging_smoke_bypass.id, precedence = 1 }]
}
