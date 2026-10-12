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
