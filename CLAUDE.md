# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Single home for the infrastructure of FJ Consulting apps: TBD (`fjcloudaiconsulting/tbd`, in prod on
DigitalOcean until cutover) and Ziftbook (`fjcloudaiconsulting/ziftbook`, pre-launch). App repos keep
app code, Dockerfiles and CI; this repo owns where and how they run. Work is tracked in Jira `INFRA`.

## Target architecture (decided 2026-10-01)

- One AWS Lightsail `medium_3_0` (4 GB) in eu-central-1, single-node k3s. No EKS, no RDS, no ALB/NAT: cost
  ceiling is ~$26/mo against limited AWS credits.
- MySQL 8.4 (TBD), Postgres 18 (Ziftbook), Valkey 8 (TBD sessions) run in-cluster as StatefulSets; nightly
  dumps go to the existing Object Lock bucket `tbd-mysql-backups-884686184019`.
- Cloudflare proxies all app traffic to Traefik (Origin CA cert, Full strict); the node only accepts 443
  from Cloudflare ranges.
- Images live on GHCR, built by the app repos. Flux (source + kustomize controllers only) applies
  `clusters/`. Secrets are SOPS + age.
- Namespaces: `tbd-prod`, `ziftbook-staging`, `data`.

## Layout and commands

- `terraform/<stack>/`: one root per HCP Terraform workspace (org `FlamaCorp`). Plan runs on the PR, apply on
  merge after approval in the TFC UI. Local CLI only for debugging.
- `clusters/<cluster>/`: Kubernetes manifests reconciled by Flux.
- CI (`.github/workflows/ci.yml`) runs `terraform fmt -check -recursive` and `init -backend=false && validate`
  for every stack. Locally: `terraform fmt -recursive` and `terraform -chdir=terraform/<stack> validate`.
- The Terraform version is pinned in `ci.yml`; keep workspaces on the same version.

## Constraints that are easy to break

- AWS account `884686184019` holds the TBD backup chain (bucket, KMS key, `pfv-backup-uploader`,
  `tfc-backups-*` roles, OIDC providers). The TFC role trust is pinned to workspace name `tbd-backups`:
  never rename it, and never edit an existing trust statement in place (add a second one, apply, then
  remove the old).
- The TBD apex site and the `thebetterdecision.com` Route 53 zone/registration live in an older, separate
  AWS account we have no credentials for; the owner acts there.
- Lightsail instance: `prevent_destroy` and `ignore_changes = [user_data]`, since replacing it destroys the
  databases.
- AWS calls go through the aws-mcp server; it runs against `884686184019`.

## Docs

Plans and specs are local only (`docs/specs/`, git-excluded). Shareable decisions go in PR bodies and Jira.
