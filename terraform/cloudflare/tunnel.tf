# Remotely managed tunnel for the Hetzner cluster (INFRA-170). tunnel_secret is omitted: Cloudflare generates it.
resource "cloudflare_zero_trust_tunnel_cloudflared" "hetzner_k3s" {
  account_id = var.account_id
  name       = "hetzner-k3s"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "hetzner_k3s" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.hetzner_k3s.id

  config = {
    ingress = [
      # Hostname rules (hostname + path -> http://<svc>.<ns>.svc.cluster.local:<port>) are added per environment in the move tickets, next to the DNS change.
      # First match wins. `path` is a regex; these mirror the old Traefik PathPrefix routes.
      # TBD staging (INFRA-173): API, health and readiness to the backend, everything else to the frontend.
      { hostname = "dev.thebetterdecision.com", path = "^/(api|health|ready)", service = "http://backend.tbd-staging.svc.cluster.local:8000" },
      { hostname = "dev.thebetterdecision.com", service = "http://frontend.tbd-staging.svc.cluster.local:3000" },
      # Ziftbook staging (INFRA-173): everything to the frontend, which proxies /api/* to the backend (as the old IngressRoute).
      { hostname = "dev.ziftbook.com", service = "http://frontend.ziftbook-staging.svc.cluster.local:3000" },
      { service = "http_status:404" },
    ]
  }
}

# Read once to pipe into a SOPS Secret without displaying it (never copy it from a run log or state).
data "cloudflare_zero_trust_tunnel_cloudflared_token" "hetzner_k3s" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.hetzner_k3s.id
}

output "hetzner_tunnel_token" {
  value     = data.cloudflare_zero_trust_tunnel_cloudflared_token.hetzner_k3s.token
  sensitive = true
}
