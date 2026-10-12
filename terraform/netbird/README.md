# `netbird`

NetBird access policies for the owner's kubectl access (INFRA-171). Only what the policy needs is here: the groups
`owner-devices` and `k3s-hetzner` are looked up by name, not managed (device membership is edited by hand; the
cluster peer joins `k3s-hetzner` through its setup key's auto-group).

| Resource | Notes |
|---|---|
| `netbird_policy` `owner-to-hetzner-k3s` | `owner-devices` -> `k3s-hetzner`, TCP 6443, one way. The peer `hetzner-k3s` (`clusters/hetzner/netbird`) forwards its NetBird IP to the node's loopback, so the API is reached at `https://hetzner-k3s.netbird.cloud:6443` (kubeconfig `tls-server-name: kubernetes`) |

Not managed here yet: the old cluster's `owner-to-k3s-api` policy (`clusters/platform/netbird/README.md`), which goes
away with the Lightsail node, and the account's disabled `Default` policy.

## Workspace

HCP Terraform `FlamaCorp/netbird`, VCS flow against this repo, working directory `terraform/netbird`, trigger pattern
`terraform/netbird/**`, manual apply. Created by the owner (not by Terraform).

- Env `NB_PAT` (**sensitive**): access token of the NetBird service user `terraform` (role Admin). Rotate by creating a
  new token on that user, replacing the variable, then deleting the old token.
