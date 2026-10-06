# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Single home for the infrastructure of FJ Consulting apps: TBD (`fjcloudaiconsulting/tbd`, in prod on this
cluster since the 2026-10-04 cutover) and Ziftbook (`fjcloudaiconsulting/ziftbook`, pre-launch). App repos keep
app code, Dockerfiles and CI; this repo owns where and how they run. Work is tracked in Jira `INFRA`.

## Target architecture (decided 2026-10-01)

- One AWS Lightsail `medium_3_0` (4 GB) in eu-central-1, single-node k3s. No EKS, no RDS, no ALB/NAT: cost
  ceiling is ~$26/mo against limited AWS credits.
- MySQL 8.4 (TBD), Postgres 18 (Ziftbook), Valkey 8 (TBD sessions) run in-cluster as StatefulSets; nightly
  dumps go to the existing Object Lock bucket `tbd-mysql-backups-884686184019`.
- Cloudflare proxies all app traffic to Traefik (Origin CA cert, Full strict); the node only accepts 443
  from Cloudflare ranges, and Traefik's `TLSOption default` requires our zone-level Authenticated Origin Pulls client
  cert (INFRA-93). It fails closed: a missing `kube-system/origin-pull-ca-<gen>` Secret takes every host down.
- Images live on GHCR, built by the app repos. Flux (source + kustomize controllers only) applies
  `clusters/`. Secrets are SOPS + age.
- Namespaces: `tbd-prod`, `tbd-staging`, `ziftbook-staging`, `data`, `observability` (Grafana Alloy, metrics to Grafana Cloud), plus `netbird` (owner kubectl access over NetBird, runbook
  `clusters/platform/netbird/README.md`).

## Layout and commands

- `terraform/<stack>/`: every directory directly under `terraform/` is a root stack, one per HCP Terraform workspace (org `FlamaCorp`). Plan runs on the PR, apply on
  merge after approval in the TFC UI. Local CLI only for debugging.
- `clusters/<cluster>/`: Kubernetes manifests reconciled by Flux.
- `aws/bootstrap/`: IAM documents for the HCP Terraform OIDC roles, minted once by root (see each stack's
  README). A workspace never manages its own role.
- `grafana/`: Grafana Cloud alert rules, contact point and dashboard as API payloads; applied by hand after merge
  (runbooks.md "Memory alerts"). Nothing applies them automatically: keep git and the stack in step.
- CI (`.github/workflows/ci.yml`) runs `terraform fmt -check -recursive -diff`, `init -backend=false && validate`
  for every stack, tflint (`.tflint.hcl`), and the Python tests (`python3 -m unittest discover -s tests`: backup probe, SOPS check). A second job runs kubeconform on
  `clusters/` and `.github/scripts/check-sops-secrets.py` (every Secret under `clusters/` must be SOPS-encrypted) and `.github/scripts/check-prod-tags.py` (every `<app>-prod` image tag <= that app's `<app>-staging` tags). Locally: `terraform fmt -recursive`,
  `terraform -chdir=terraform/<stack> validate`, and `tflint --init && tflint --recursive --config "$PWD/.tflint.hcl"`.
- The Terraform version is pinned in `ci.yml`; keep workspaces on the same version.

## Constraints that are easy to break

- AWS account `884686184019` holds the TBD backup chain (bucket, KMS key, `k3s-backup-uploader`,
  `tfc-backups-*` roles, OIDC providers). The TFC role trust is pinned to workspace name `tbd-backups`:
  do not rename it. If a rename is ever unavoidable, or any trust statement must change, add the new
  statement, apply, then remove the old one; never edit in place.
- The `thebetterdecision.com` registration (Route 53 Domains) lives in an older, separate
  AWS account we have no credentials for; the owner acts there. The TBD apex is the Worker `tbd-landing`. DNS for the domain is served by Cloudflare
  (`terraform/cloudflare`) since 2026-10-01; the old Route 53 zone is kept only until INFRA-58 deletes it.
- Lightsail instance: `prevent_destroy` and `ignore_changes = [user_data]`, since replacing it destroys the
  databases.
- AWS calls go through the aws-mcp server; it runs against `884686184019`.

## Docs

Plans and specs are local only (`docs/specs/`, git-excluded). Shareable decisions go in PR bodies and Jira.

`docs/configuration-map.md` lists every setting made by hand outside git and a symptom table for when one breaks. Update it in the same PR as any such change.
`docs/runbooks.md` holds the step-by-step procedures (Secrets, hostnames and Origin CA certs, Mailgun, TBD smoke account, origin pull certificates, following Flux and rollouts, the post-deploy smoke, node memory and the upsize, metrics to Grafana Cloud, Cloudflare API tokens); update it when a procedure changes.

<!-- claude-mem-lite:begin v1 -->
## claude-mem-lite — persistent memory

PreToolUse hooks already run `mem_recall` for past lessons before Read/Edit/Write. The calls worth making proactively:

| When | Call |
|------|------|
| Before Edit/Write | hook already recalled; if an injected `#NN` lesson changed what you did, add the bare tag `(#NN)` once at the end of the sentence describing that change (citing = adopting; uncited lessons decay; skip ones that did not apply). No other mention of memory ids, saves or the memory store in replies to the user |
| A recalled memory drives an answer or a design choice | check its claim in the code or `git log` first: `#NN` and `E#NN` rows are notes from past sessions, many written automatically, so they can be wrong, and they describe the code as it was. If the code disagrees, trust the code and replace the note: `mem_save(..., supersedes=[NN])`, or `supersedes=["E#NN"]` for an event |
| After fixing a non-trivial bug | `mem_save(type="bugfix", lesson_learned="<root cause + fix, only what this change's diff shows>", importance=2)` |
| After a non-obvious architecture decision | `mem_save(type="decision", lesson_learned="<constraint + tradeoff>")` |
| Deferring to a future session | `mem_defer({title, priority:1|2|3, detail})`; when fixed, add `closes_deferred=[N]` to `mem_save` |
| Looking up past work / history | `mem_search "keywords"` · `mem_recent` · `mem_timeline` |

Path cost is round-trips, not milliseconds: the PreToolUse hook above already recalls (0 calls) — prefer it. For an explicit query, if these `mem_*` tools are deferred behind ToolSearch this session, the Bash CLI `claude-mem-lite` is one call vs two (ToolSearch + call); the MCP server instructions carry the absolute path to use when it is not on PATH.

Full tool + CLI tables, citation/decay rules, and save discipline → `.claude/plugin_claude_mem_lite.md`
<!-- claude-mem-lite:end -->

## graphify

- **graphify** (`~/.claude/skills/graphify/SKILL.md`) - any input to knowledge graph. Trigger: `/graphify`.
  When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.
