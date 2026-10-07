# Block Worker subrequests to every hostname except the landing Workers' own (INFRA-136, follow-up of INFRA-98). Nothing
# fetches the node hostnames from a Worker (the landing Workers serve the apex and www only), so a request that comes
# from a Worker (cf.worker.upstream_zone is non-empty) is never legitimate there. Fail-closed: a node hostname added
# later is covered without editing this list. Visitor traffic has an empty value and is unaffected.
#
# Neither zone had an http_request_firewall_custom entrypoint before this one (read 2026-10-07). A rule added in the
# dashboard is drift that the next apply removes. Back out with enabled = false. Free plan: 5 custom rules per zone.
# Untested against a live Worker when written: verify after apply (docs/configuration-map.md, INFRA-98).
#
# The workspace token needs Zone WAF: Edit on both zones (docs/configuration-map.md, HCP Terraform).
locals {
  landing_hostnames = {
    tbd      = ["thebetterdecision.com", "www.thebetterdecision.com"]
    ziftbook = ["ziftbook.com", "www.ziftbook.com"]
  }
}

resource "cloudflare_ruleset" "block_worker_subrequests" {
  for_each = local.landing_hostnames

  zone_id = local.app_zones[each.key]
  name    = "default"
  kind    = "zone"
  phase   = "http_request_firewall_custom"

  rules = [{
    ref         = "block_worker_subrequests"
    description = "Block Worker subrequests outside the landing hostnames (INFRA-136)"
    expression  = "(not http.host in {${join(" ", [for h in each.value : jsonencode(h)])}} and cf.worker.upstream_zone ne \"\")"
    action      = "block"
    enabled     = true
  }]
}
