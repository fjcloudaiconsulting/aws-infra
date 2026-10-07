# Block Worker subrequests to the node hostnames (INFRA-136, follow-up of INFRA-98). No code on these hostnames makes
# same-zone subrequests (the landing Workers serve the apex and www only), so a request that comes from a Worker
# (cf.worker.upstream_zone is non-empty) is never legitimate there. Visitor traffic has an empty value and is unaffected.
#
# Neither zone had an http_request_firewall_custom entrypoint before this one (read 2026-10-07). A rule added in the
# dashboard is drift that the next apply removes. Back out with enabled = false. Free plan: 5 custom rules per zone.
# Untested against a live Worker when written: verify after apply (docs/configuration-map.md, INFRA-98).
#
# The workspace token needs Zone WAF: Edit on both zones (docs/configuration-map.md, HCP Terraform).
locals {
  node_hostnames = {
    tbd      = ["ping.thebetterdecision.com", "app.thebetterdecision.com", "dev.thebetterdecision.com"]
    ziftbook = ["dev.ziftbook.com", "app.ziftbook.com"]
  }
}

resource "cloudflare_ruleset" "block_worker_subrequests" {
  for_each = local.node_hostnames

  zone_id = local.app_zones[each.key]
  name    = "default"
  kind    = "zone"
  phase   = "http_request_firewall_custom"

  rules = [{
    ref         = "block_worker_subrequests"
    description = "Block Worker subrequests to node hostnames (INFRA-136)"
    expression  = "(http.host in {${join(" ", [for h in each.value : jsonencode(h)])}} and cf.worker.upstream_zone ne \"\")"
    action      = "block"
    enabled     = true
  }]
}
