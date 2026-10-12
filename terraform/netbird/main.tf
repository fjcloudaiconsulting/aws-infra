# Every NetBird object the clusters depend on (INFRA-171). Group membership is code: a device or cluster peer joins a
# group by adding its peer name below, and an apply removes members added by hand or by a setup key's auto-group. The
# built-in group "All" and the account's disabled "Default" policy are NetBird's and stay unmanaged.

locals {
  # Peer names as shown in the dashboard (the peer's NB_HOSTNAME or the device's hostname).
  group_members = {
    owner_devices = ["arvore"]
    k3s           = ["platform-node"]
    k3s_hetzner   = ["hetzner-k3s"]
  }
}

data "netbird_peer" "member" {
  for_each = toset(flatten(values(local.group_members)))
  name     = each.value
}

# Created in the dashboard, imported 2026-10-12. The dashboard name had a trailing space ("owner-devices "); the import
# corrects it.
import {
  to = netbird_group.owner_devices
  id = "davnd72fadhs73fbp140"
}

resource "netbird_group" "owner_devices" {
  name  = "owner-devices"
  peers = [for n in local.group_members.owner_devices : data.netbird_peer.member[n].id]
}

# The Lightsail cluster's peer (clusters/platform/netbird). Goes with the Lightsail node.
import {
  to = netbird_group.k3s
  id = "davnd2qfadhs73fblqcg"
}

resource "netbird_group" "k3s" {
  name  = "k3s"
  peers = [for n in local.group_members.k3s : data.netbird_peer.member[n].id]
}

# The Hetzner cluster's peer (clusters/hetzner/netbird), auto-assigned by its setup key.
import {
  to = netbird_group.k3s_hetzner
  id = "db6bs2bl0ubs739ujl40"
}

resource "netbird_group" "k3s_hetzner" {
  name  = "k3s-hetzner"
  peers = [for n in local.group_members.k3s_hetzner : data.netbird_peer.member[n].id]
}

# Both cluster peers run with hostNetwork, so traffic to a peer's NetBird IP lands on the node's loopback, where the API
# server listens. These rules (TCP 6443, one way) are the only thing that exposes it; any wider rule would also expose
# the kubelet and every other loopback listener.

import {
  to = netbird_policy.owner_to_k3s_api
  id = "davnfp2fadhs73fdffq0"
}

resource "netbird_policy" "owner_to_k3s_api" {
  name    = "owner-to-k3s-api"
  enabled = true

  rule {
    name          = "owner-to-k3s-api"
    action        = "accept"
    bidirectional = false
    enabled       = true
    protocol      = "tcp"
    ports         = ["6443"]
    sources       = [netbird_group.owner_devices.id]
    destinations  = [netbird_group.k3s.id]
  }
}

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
    sources       = [netbird_group.owner_devices.id]
    destinations  = [netbird_group.k3s_hetzner.id]
  }
}
