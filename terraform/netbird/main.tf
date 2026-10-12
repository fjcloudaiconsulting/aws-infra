# Groups are looked up, not managed: owner-devices membership is edited by hand per device, and k3s-hetzner is
# filled by the setup key's auto-group. Managing them here would fight both.
data "netbird_group" "owner_devices" {
  name = "owner-devices"
}

data "netbird_group" "k3s_hetzner" {
  name = "k3s-hetzner"
}

# Owner kubectl to the Hetzner cluster (INFRA-171). The peer hetzner-k3s runs with hostNetwork, so traffic to its
# NetBird IP lands on the node's loopback, where the API server listens. This rule (TCP 6443, one way) is the only
# thing that exposes it; any wider rule would also expose the kubelet and every other loopback listener.
resource "netbird_policy" "owner_to_hetzner_k3s" {
  name        = "owner-to-hetzner-k3s"
  description = "Owner devices to the Hetzner k3s API (TCP 6443). Managed by cloud-infra terraform/netbird."
  enabled     = true

  rule {
    name          = "owner-to-hetzner-k3s"
    action        = "accept"
    bidirectional = false
    enabled       = true
    protocol      = "tcp"
    ports         = ["6443"]
    sources       = [data.netbird_group.owner_devices.id]
    destinations  = [data.netbird_group.k3s_hetzner.id]
  }
}

# The rule only reaches the cluster if its peer is in the destination group (the setup key's auto-group).
check "hetzner_peer_in_group" {
  assert {
    condition     = length(data.netbird_group.k3s_hetzner.peers) > 0
    error_message = "Group k3s-hetzner has no peers: the Hetzner peer is not in it, so the policy reaches nothing."
  }
}
