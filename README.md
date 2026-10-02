# aws-infra

Infrastructure that hosts FJ Consulting applications (TBD, Ziftbook). App repos keep app code,
Dockerfiles and their own CI; everything about where and how the apps run lives here.

## Layout

| Path | What | Applied by |
|---|---|---|
| `terraform/<stack>/` | One Terraform root per HCP Terraform workspace (org `FlamaCorp`) | HCP Terraform VCS flow: plan on PR, apply on merge after approval in the TFC UI |
| `clusters/<cluster>/` | Kubernetes manifests | Flux, reconciling `main` |
| `aws/bootstrap/` | IAM trust and permission documents for the HCP Terraform roles (a workspace never manages its own role) | Root, once by CLI; see each stack's README |

## Rules

- Terraform runs through HCP Terraform only. CLI plan/apply is for debugging.
- Terraform version is pinned to the one in `.github/workflows/ci.yml`; workspaces use the same.
- Do not rename a workspace whose name is pinned in an AWS trust policy (e.g. `tbd-backups`). If a
  rename is ever unavoidable: add a trust statement for the new name, apply, rename, then remove the
  old statement. The same add-apply-remove order applies to any trust policy edit.
- Secrets never land in plain text: Terraform variables are sensitive TFC variables, Kubernetes
  secrets are SOPS-encrypted.

## Kubernetes secrets

A Secret lives in its own `clusters/**/<name>.secret.yaml`; `.sops.yaml` encrypts its `data` and
`stringData` to the cluster's age key, and CI fails on any Secret that is not encrypted. Flux
decrypts with the private key held in-cluster as `flux-system/sops-age`.

```sh
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt   # sops looks elsewhere on macOS
sops encrypt -i clusters/platform/<path>/<name>.secret.yaml
sops edit clusters/platform/<path>/<name>.secret.yaml   # later changes
```

Encrypting needs only the public key in `.sops.yaml`; editing needs the private key (offline backup).

Bootstrap on a fresh cluster (once): create namespace `flux-system` and the Secret `sops-age` with the
private key under a name ending in `.agekey` (Flux ignores other names), then
`kubectl apply -f clusters/platform/flux-system/gotk-components.yaml`, wait for the controllers, and
`kubectl apply -f clusters/platform/flux-system/gotk-sync.yaml`.
Not `apply -k`: the encrypted Secrets in the folder fail kubectl validation; Flux applies them.

## AWS credits (account 884686184019)

Read from Billing and Cost Management > Credits on 2026-10-01:

| Credit | Issued | Remaining | Expires |
|---|---|---|---|
| AWS Free Tier | $100.00 | $99.90 | 2027-08-27 |
| Explore AWS: Set up a cost budget using AWS Budgets | $20.00 | $20.00 | 2027-08-27 |
| Explore AWS: Launch an instance using EC2 | $20.00 | $20.00 | 2027-08-27 |
| **Total** | $140.00 | **$139.90** (estimated $138.83) | |

At the planned ~$26/month (Lightsail `medium_3_0` plus extras) the credits last about five months
from the node's launch, well before they expire, assuming they apply to Lightsail (not confirmed:
check the first invoice after launch). Re-read and update this table when planning spend.

Work is tracked in Jira project [INFRA](https://fjconsulting.atlassian.net/jira/software/c/projects/INFRA/).
