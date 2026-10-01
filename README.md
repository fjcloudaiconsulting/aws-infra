# aws-infra

Infrastructure that hosts FJ Consulting applications (TBD, Ziftbook). App repos keep app code,
Dockerfiles and their own CI; everything about where and how the apps run lives here.

## Layout

| Path | What | Applied by |
|---|---|---|
| `terraform/<stack>/` | One Terraform root per HCP Terraform workspace (org `FlamaCorp`) | HCP Terraform VCS flow: plan on PR, apply on merge after approval in the TFC UI |
| `clusters/<cluster>/` | Kubernetes manifests | Flux, reconciling `main` |

## Rules

- Terraform runs through HCP Terraform only. CLI plan/apply is for debugging.
- Terraform version is pinned to the one in `.github/workflows/ci.yml`; workspaces use the same.
- Never rename a workspace whose name is pinned in an AWS trust policy (e.g. `tbd-backups`); add a
  second trust statement first, then rename, then remove the old one.
- Secrets never land in plain text: Terraform variables are sensitive TFC variables, Kubernetes
  secrets are SOPS-encrypted.

Work is tracked in Jira project [INFRA](https://fjconsulting.atlassian.net/jira/software/c/projects/INFRA/).
