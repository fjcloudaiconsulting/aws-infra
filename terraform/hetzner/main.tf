locals {
  nodes = {
    node-1 = { role = "app", ip = "10.0.1.11" }
    node-2 = { role = "app", ip = "10.0.1.12" }
    db-1   = { role = "db", ip = "10.0.1.21" }
  }
}

resource "hcloud_ssh_key" "deploy" {
  name       = "fjc-hetzner-deploy"
  public_key = var.deploy_ssh_public_key
}

resource "hcloud_network" "main" {
  name     = "fjc-platform"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "main" {
  network_id   = hcloud_network.main.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.1.0/24"
}

resource "hcloud_placement_group" "main" {
  name = "fjc-platform"
  type = "spread"
}

# SSH only: apps come in through Cloudflare Tunnel (outbound only), and Hetzner firewalls do not filter the private network k3s uses.
resource "hcloud_firewall" "nodes" {
  name = "fjc-platform-nodes"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.ssh_allowed_cidrs
  }
}

# Primary IPs outlive the servers (auto_delete false), so a rebuilt node keeps its address for the static Ansible inventory.
resource "hcloud_primary_ip" "node" {
  for_each = local.nodes

  name        = "fjc-${each.key}"
  type        = "ipv4"
  location    = var.location
  auto_delete = false

  delete_protection = true
}

resource "hcloud_server" "node" {
  for_each = local.nodes

  name               = each.key
  server_type        = var.server_type
  location           = var.location
  image              = "ubuntu-24.04"
  ssh_keys           = [hcloud_ssh_key.deploy.id]
  firewall_ids       = [hcloud_firewall.nodes.id]
  placement_group_id = hcloud_placement_group.main.id
  labels             = { role = each.value.role }

  # GHCR is IPv4 only.
  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.node[each.key].id
    ipv6_enabled = false
  }

  network {
    network_id = hcloud_network.main.id
    ip         = each.value.ip
    alias_ips  = []
  }

  depends_on = [hcloud_network_subnet.main]

  # A key or image change must not replace a node (and its data); rebuild by tainting instead.
  lifecycle {
    ignore_changes = [image, ssh_keys]
  }
}

# The databases live here; Ansible mounts it with a guard. No Hetzner backups: they do not cover volumes, the S3 dumps are the backup.
resource "hcloud_volume" "db" {
  name              = "fjc-db"
  size              = 40
  location          = var.location
  format            = "ext4"
  automount         = false
  delete_protection = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "hcloud_volume_attachment" "db" {
  volume_id = hcloud_volume.db.id
  server_id = hcloud_server.node["db-1"].id
  automount = false
}
