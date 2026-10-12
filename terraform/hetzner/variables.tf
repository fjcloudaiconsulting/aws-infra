variable "ssh_allowed_cidrs" {
  description = "IPv4 CIDRs allowed to reach port 22 on every node (the only inbound rule). Set as a workspace variable."
  type        = list(string)

  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0 && alltrue([for c in var.ssh_allowed_cidrs : can(cidrnetmask(c)) && !endswith(c, "/0")])
    error_message = "ssh_allowed_cidrs must be a non-empty list of IPv4 CIDRs (not /0), for example 203.0.113.7/32."
  }
}

variable "deploy_ssh_public_key" {
  description = "Public key Ansible uses to reach the nodes (ed25519). Set as a workspace variable."
  type        = string

  validation {
    condition     = startswith(var.deploy_ssh_public_key, "ssh-ed25519 ")
    error_message = "deploy_ssh_public_key must be an OpenSSH ed25519 public key (starts with \"ssh-ed25519 \")."
  }
}

variable "location" {
  description = "Hetzner location for the servers, primary IPs and volume."
  type        = string
  default     = "nbg1"
}

variable "server_type" {
  description = "Server type for all three nodes."
  type        = string
  default     = "cx33"
}
