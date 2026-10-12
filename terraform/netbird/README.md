# `netbird`

Every NetBird object the clusters depend on (INFRA-171): the groups and the owner's kubectl policies. The first three
groups and `owner-to-k3s-api` were made in the dashboard and imported on 2026-10-12.

| Resource | Notes |
|---|---|
| `netbird_group` `owner-devices` | The owner's devices (peer `arvore`). The dashboard name had a trailing space, fixed by the first apply |
| `netbird_group` `k3s` | Lightsail peer `platform-node` (`clusters/platform/netbird`) |
| `netbird_group` `k3s-hetzner` | Hetzner peer `hetzner-k3s` (`clusters/hetzner/netbird`) |
| `netbird_policy` `owner-to-k3s-api` | `owner-devices` -> `k3s`, TCP 6443, one way |
| `netbird_policy` `owner-to-hetzner-k3s` | `owner-devices` -> `k3s-hetzner`, TCP 6443, one way. API at `https://hetzner-k3s.netbird.cloud:6443` (kubeconfig `tls-server-name: kubernetes`) |

Both cluster peers forward their NetBird IP to the node's loopback (hostNetwork), so these rules are the only thing that
exposes the API server. Membership is code: add a device by adding its peer name to `local.group_members` in
`main.tf`. An apply removes members added any other way, including by a setup key's auto-group, so add a new cluster
peer here right after it enrols. Unmanaged: the built-in group `All` and the account's disabled `Default` policy.

## Workspace

HCP Terraform `FlamaCorp/netbird`, VCS flow against this repo, working directory `terraform/netbird`, trigger pattern
`terraform/netbird/**`, manual apply. Created by the owner (not by Terraform).

- Env `NB_PAT` (**sensitive**): access token of the NetBird service user `terraform` (role Admin). Rotate by creating a
  new token on that user, replacing the variable, then deleting the old token.
