# Edge rate limit on the apps' sign-in and token endpoints (INFRA-123). A burst from one address stops at Cloudflare
# with a 429 instead of costing the app's database one write per attempt. Each app keeps its own per-account and
# per-address limits behind this; the rule only caps volume.
#
# Both zones are on the Free plan, which allows (read 2026-10-04): one rate-limiting rule per zone, the URI path as
# the only request field (no host, no method), counting per client IP and Cloudflare data center (ip.src and
# cf.colo.id, both required), a 10 s period, a 10 s block and the block action, which answers 429. So the rule has no
# host condition and covers every proxied host of the zone at once (TBD app. and dev., Ziftbook dev. and any later
# production host). DNS-only records, like the TBD apex on CloudFront, never reach it.
#
# One counter per address for all paths of a zone. 20 requests in 10 s is far above a person signing in (a few
# requests) and above the TBD post-deploy smoke test (one login). GET /api/session on ziftbook.com shares the path of
# the sign-in POST, so it counts too: the console reads it once per load and once per write. Paths are exact: the
# zones' URL normalization (incoming, Cloudflare) runs before this phase, and a trailing-slash variant never reaches a
# handler (TBD redirects it, Ziftbook answers 404).
#
# Neither zone had an http_ratelimit entrypoint ruleset before this one. A rule added in the dashboard is drift that
# the next apply removes. Back out with enabled = false.
#
# The workspace token needs Zone WAF: Edit on both zones (docs/configuration-map.md, HCP Terraform).
locals {
  auth_rate_limit_paths = {
    tbd = [
      "/api/v1/auth/login",
      "/api/v1/auth/register",
      "/api/v1/auth/forgot-password",
      "/api/v1/auth/reset-password",
      "/api/v1/auth/verify-email",
      "/api/v1/auth/resend-verification-public",
      "/api/v1/auth/mfa/verify",
      "/api/v1/auth/mfa/recovery",
      "/api/v1/auth/mfa/email-code",
      "/api/v1/auth/mfa/email-verify",
      "/api/v1/auth/google/callback",
      "/api/v1/orgs/invitations/accept",
    ]
    ziftbook = [
      "/api/session",
      "/api/sign-up",
      "/api/sign-up/complete",
      "/api/password-reset",
      "/api/password-reset/complete",
      "/api/invites/lookup",
      "/api/invites/accept",
      "/api/public/booking-link/session",
    ]
  }
}

resource "cloudflare_ruleset" "auth_rate_limit" {
  for_each = local.auth_rate_limit_paths

  zone_id = local.app_zones[each.key]
  name    = "default"
  kind    = "zone"
  phase   = "http_ratelimit"

  rules = [{
    ref         = "auth_burst"
    description = "Auth endpoints: 20 requests per 10 s per IP, then 429 (INFRA-123)"
    expression  = "(http.request.uri.path in {${join(" ", [for p in each.value : jsonencode(p)])}})"
    action      = "block"
    enabled     = true
    ratelimit = {
      characteristics     = ["ip.src", "cf.colo.id"]
      period              = 10
      requests_per_period = 20
      mitigation_timeout  = 10
    }
  }]
}
