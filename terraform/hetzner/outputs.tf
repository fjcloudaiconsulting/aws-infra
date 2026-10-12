output "nodes" {
  description = "Public IPv4 and private IP per node, for the Ansible inventory."
  value = {
    for k, s in hcloud_server.node : k => {
      public_ipv4 = s.ipv4_address
      private_ip  = local.nodes[k].ip
    }
  }
}

output "db_volume_device" {
  description = "Linux device of the DB volume on db-1, for the Ansible mount."
  value       = hcloud_volume.db.linux_device
}
