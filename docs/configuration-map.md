# Configuration map

Settings that live **outside git**: GitHub org and repo settings, GitHub Apps, Mend Renovate, HCP
Terraform, AWS, Cloudflare, the cluster's out-of-band secrets, Jira. They were set by hand in UIs and
consoles, so git cannot show drift and a wrong value fails silently. This page says what is set, where,
what depends on it, and how it shows when it breaks. Names only: secret values never go in this repo
(it is public).

Verified against the live settings on 2026-10-03. When you change any setting below, change this page
in the same PR or right after.

## When something breaks

| Symptom | Likely cause | Look at | Fix |
|---|---|---|---|
| Release job fails with `Resource not accessible by integration` on create-a-release | The release App token lacks `workflows`. GitHub treats a new tag as creating workflow files when a later `main` commit changed one | [Release chain](#release-and-deploy-chain) step 4, [GitHub Apps](#github-apps) | Org owner: App permissions > Workflows: Read and write, then accept on the org installation. Re-run the failed job |
| Release job is green but `promote` and `smoke` are skipped, no tag | `main` moved on after the release PR merged ("main is at X; skipping"). Expected | The newer main run | Nothing, the newest commit's run releases it. If the newest run also skipped or failed, re-run it |
| No release PR after a merge | Only `feat`, `fix`, `perf`, `revert` and breaking commits release (Renovate's `fix(deps):` does); `chore`, `ci`, `docs`, `build`, `test`, `refactor`, `style` do not. Or the release job failed | Run of the merge commit, job `Release PR and tag` | Fix the job; a `chore` merge alone never opens one |
| Staging image bump sits on a `renovate/ziftbook-staging-*` branch and never merges, or shows up as a PR | Renovate app is not a bypass actor on the aws-infra ruleset, or CI did not run on the branch | [Rulesets](#branch-protection), `ci.yml` push filter | Ruleset > Bypass list > Renovate (app) > Always. CI must report `Terraform checks` and `Kubernetes checks` on the branch |
| No app image bumps, Dependency Dashboard lists `ghcr.io` lookup failures (other dependencies still get PRs) | `GHCR_READ_TOKEN` (Mend org secret) expired or revoked | [Mend Renovate](#mend-renovate) | New classic PAT with only `read:packages`, owned by GitHub user `flamarion` (the username is fixed in `renovate.json` hostRules); replace the Mend secret, tick "run again" on the dashboard |
| `ImagePullBackOff` in `ziftbook-staging` or `tbd-prod` | The `ghcr-pull` credential expired or was revoked | `clusters/platform/namespaces/*-ghcr-pull.secret.yaml` | Re-encrypt a new GHCR read credential into both files (see [Cluster](#cluster-out-of-band-material)) |
| `kubectl`/`flux` cannot connect | NetBird client not connected, or the `owner-admin` token expired | [`netbird/README.md`](../clusters/platform/netbird/README.md) | Connect NetBird; renew the token per the runbook |
| A pod or Job in `ziftbook-staging` is never created (`FailedCreate`, "exceeded quota: staging-class-only") | Every pod there must set `priorityClassName: staging`; the quota rejects any other, Jobs and CronJobs included | `kubectl -n ziftbook-staging get events` | Add `priorityClassName: staging` and explicit memory requests that fit the `memory` quota |
| Flux shows the Kustomization Ready but a workload is down | `flux-system` has no `healthChecks`: pod, quota or PSA failures do not turn it red | `kubectl -n <ns> get pods,events` | Fix the manifest. Namespace limits: [`namespaces/ziftbook-staging.yaml`](../clusters/platform/namespaces/ziftbook-staging.yaml) |
| Flux cannot apply a `*.secret.yaml` | `flux-system/sops-age` missing or holds the wrong key | README, Kubernetes secrets | Recreate the secret from the offline key |
| Ziftbook staging sends no mail (once ZIF-151 ships) | Secret `ziftbook-mailgun` (key `api-key`) missing (the worker starts without it), or the Mailgun domain is not verified | `kubectl -n ziftbook-staging logs deploy/worker`, Mailgun domain status | Write `ziftbook-mailgun.secret.yaml` (INFRA-47 guide, part D), then `kubectl -n ziftbook-staging rollout restart deploy/worker` (env is read at pod start), or fix the DNS records until Mailgun shows the domain verified |
| Cloudflare 526 on a proxied host | Traefik serves the wrong cert: the zone's Secret (`kube-system/origin-cert` for thebetterdecision.com, `origin-cert-ziftbook` for ziftbook.com) is missing or its Origin CA cert expired | `clusters/platform/traefik/` (applied to namespace `kube-system`), Cloudflare SSL/TLS > Origin Server of that zone | Issue a new Origin CA cert in that zone, re-encrypt its `*.secret.yaml` |
| A PR has no `Terraform Cloud/FlamaCorp/<ws>` check | Workspace missing, or its trigger path was not touched. Re-running GitHub checks does not trigger a plan | HCP Terraform workspace | An absent check is not a pass. Push a change under the stack's directory |
| `aws` says "session has expired", aws-mcp tools missing | Root login session expired | n/a | Owner runs `aws login --profile tbd` |
| Ziftbook Renovate PR fails `pnpm install` with `ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION` | A package version is younger than pnpm's 1 day policy | INFRA-77 | Re-run CI a day later |
| Alarm emails never arrive | SNS email subscriptions deliver only after the recipient confirms | AWS SNS topics `platform-alerts`, `platform-alerts-use1` | Click the confirmation link in the subscription email |
| tbd release run red at `deploy`, an undeployed-release issue opens, tbd `deploy-drift-probe` red | Expected since the INFRA-48 cutover: tbd's `DIGITALOCEAN_ACCESS_TOKEN` secret was overwritten so no release un-archives the DigitalOcean app | [DigitalOcean](#digitalocean-rollback-target-until-infra-49) | Nothing; the k3s deploy is the Renovate bump PR. INFRA-49 removes the DO jobs. Never restore the token except in a rollback |

## Release and deploy chain

Every arrow depends on a setting listed in this page. The chain is proven end to end for Ziftbook
staging (v0.20.2, 2026-10-03). TBD production (`tbd-prod`, since the INFRA-48 cutover) bumps arrive as
PRs and are never automerged (proven by Renovate dry run only, check it on the first TBD bump).

| # | Step | Needs |
|---|---|---|
| 1 | PR merged to the app repo's `main` | Branch protection, required checks |
| 2 | CI on `main` builds `sha-<7>` images | Shared workflow `build-image@v1` in `fjcloudaiconsulting/.github` |
| 3 | release-please opens or updates the release PR | Release App token, environment `release`, secrets `RELEASE_APP_ID` and `RELEASE_APP_PRIVATE_KEY` |
| 4 | Owner merges the release PR; the release job creates the tag and GitHub release at the release commit | App permission **Workflows: write** |
| 5 | `promote` retags the `sha-` image as `vX.Y.Z` (same digest, never rebuilt); `smoke` runs | `sha-` image still on GHCR, `promote-release@v1` |
| 6 | Renovate in aws-infra sees the new tag and pushes `renovate/ziftbook-staging-ziftbook-images` | `GHCR_READ_TOKEN`, regex versioning in `renovate.json` |
| 7 | CI runs on that branch push | `ci.yml` `push` filter `renovate/ziftbook-staging-**` |
| 8 | Renovate fast-forwards the branch into `main` without a PR | Renovate app in the `main protection` bypass list |
| 9 | Flux applies the commit; Deployments use `Recreate` | `sops-age`, `ghcr-pull` |

Drift watch: workflow `release-drift-probe.yml` (daily) opens or updates one `[release-drift]` issue when an app's latest GitHub release has been absent from `clusters/` for 2+ days (production bump PR unmerged, or Renovate never opened it), and closes it when clear. No credentials; it reads the app repos' releases because GHCR is private. It depends on `tbd` and `ziftbook` staying public repos (GITHUB_TOKEN reads); the run goes red if either goes private. Only repos in `WATCH_REPOS` (default `ziftbook tbd`, tbd since the INFRA-48 cutover) are checked.

## GitHub

Org `fjcloudaiconsulting` is on the **Free** plan: no org-level rulesets (the API answers 403), and
private repositories cannot have branch protection, so every repo that must be protected is public.

### Branch protection

| Repo | Mechanism | Rules |
|---|---|---|
| aws-infra | Ruleset `main protection` (id 24298796) | PR with 1 approval (squash only), linear history, no force-push or deletion, required checks `Terraform checks` and `Kubernetes checks` (strict). Bypass: org admin, repository admin role, **Renovate app (id 2740, Always, added 2026-10-03)** |
| .github | Ruleset `main protection` (id 24298798) | PR with 1 approval (squash only), linear history, no force-push or deletion, no required checks. Bypass: org admin, repository admin role. Ruleset `tag protection` (id 24413637, INFRA-76) on `refs/tags/v*`: restrict creations, updates, deletions, block force pushes; bypass org admin only (the owner moves `v1`; the release App is not installed here) |
| app-template | Ruleset `main protection` (id 24384611) | Same as `.github`: PR with 1 approval, linear history, no required checks |
| ziftbook | Classic branch protection | 1 review, strict checks `Backend Checks`, `Frontend Checks`, `pr-title / check`, admins not enforced. **Force-push and deletion of `main` are allowed** |
| tbd | Classic branch protection | 1 review, checks `Backend Checks`, `Frontend Checks`, admins enforced |

### GitHub Apps

Org settings > GitHub Apps (installations). Permission changes ask the org owner to accept on the
installation, and the grant applies to **every repository in the installation**.

| App | Repos | Notes |
|---|---|---|
| `fjcloudaiconsulting-release` | selected: each app repo on the shared release flow (Ziftbook, app-template) | Permissions: contents, issues, pull requests write; metadata read; **workflows write** (added 2026-10-03, INFRA-78). Private key held by the owner and stored only as the `release` environment secret. Keep `.github` and aws-infra out of the selection so this key cannot move the `v1` tag or add a workflow there (`renovate` and `claude` already hold contents and workflows write on those repos) |
| `renovate` (Mend) | selected: `.github`, aws-infra, ziftbook | tbd is not installed yet. Repos are added on GitHub, not in Mend |
| `terraform-cloud`, `digitalocean`, `gitguardian`, `atlassian`, `claude`, `tbd-branch-protection-probe` | various | Not part of the release chain. `atlassian` links PRs to Jira |

### Per-repo settings

- **Environment `release`** (Ziftbook; create the same in every new app repo, app-template does not ship
  it): deployment branches limited to `main`, **no required reviewers** (the job runs on every `main`
  push, a reviewer would block each one), secrets `RELEASE_APP_ID` and `RELEASE_APP_PRIVATE_KEY`.
- Ziftbook repo secret `CLOUDFLARE_API_TOKEN`: deploys the landing Worker.
- Actions default workflow permission is read-only everywhere checked; "allow Actions to approve PRs" is on in ziftbook, tbd and app-template.
- `.github` hosts the contract, the reusable workflows, the Renovate preset and the weekly conformance
  probe. Apps consume them by the moving major tag `@v1`; changing a workflow means tagging a new semver
  and moving `v1` (owner approval, public contract).

## Mend Renovate

Hosted Mend app, Free plan, repos selected at
`https://github.com/organizations/fjcloudaiconsulting/settings/installations/167278400`.

- **`GHCR_READ_TOKEN`**: Mend org secret, a classic PAT with only `read:packages`, 90-day expiry, created
  2026-10-02 (expires around 2026-12-31). aws-infra's `renovate.json` reads it as
  `{{ secrets.GHCR_READ_TOKEN }}`; Mend rejects encrypted secrets in repo config. Rotation: new token,
  replace the Mend secret.
- aws-infra rules in `renovate.json`: database majors never proposed (data dirs upgrade by hand after a
  fresh dump); `ghcr.io/fjcloudaiconsulting/**` tracks `vX.Y.Z` only, no digest pin, production bumps stay
  PRs; manifests under `clusters/**/ziftbook-staging/**` bump in one grouped branch and automerge by
  branch.
- Each repo has a Dependency Dashboard issue; ticking "run again" there forces a run.
- Local dry run (check a config without waiting for Mend): Node 24, then `renovate --platform=local --dry-run=full` with `GITHUB_COM_TOKEN`, `RENOVATE_TOKEN` and `RENOVATE_SECRETS='{"GHCR_READ_TOKEN":"..."}'` in the environment. The local platform reads only committed files, and `local>` presets do not resolve there.

## HCP Terraform

Org `FlamaCorp`. Workspaces are created by the owner in the UI (VCS flow, plan on PR, apply on merge
after approval in the UI). The workspace name must equal the `cloud` block name, and the `tbd-backups`
name is pinned in an AWS trust policy: never rename it.

| Workspace | Stack | Auth |
|---|---|---|
| `aws-platform` | `terraform/platform` | OIDC: env vars `TFC_AWS_PROVIDER_AUTH=true`, `TFC_AWS_PLAN_ROLE_ARN`, `TFC_AWS_APPLY_ROLE_ARN`. Optional variable `ssh_allowed_cidrs` is unset: port 22 is reachable only from the Lightsail browser console |
| `cloudflare` | `terraform/cloudflare` | Sensitive env var `CLOUDFLARE_API_TOKEN` (account-scoped, must cover zones thebetterdecision.com, ziftbook.com and fjconsulting.dev); variable `account_id` |
| `tbd-backups` | `terraform/tbd-backups` | OIDC, two roles (plan, provisioner); variable `aws_account_id` |
| `tbd-apex` | `terraform/tbd-apex` | Old AWS account: `TFC_AWS_RUN_ROLE_ARN` by design, variables `domain`, `aws_region`, `aws_account_id`; see its README |

The org also holds workspaces `tbd` (repo tbd, `infra/terraform`) and `fjconsulting-website`, which belong to those repos. CI pins Terraform 1.16.5; check the workspaces' Terraform version matches after a bump.

Never set `TFC_AWS_RUN_ROLE_ARN` on `aws-platform` or `tbd-backups`: it would give unapproved PR plans the apply role. The IAM documents are
in [`aws/bootstrap/`](../aws/bootstrap/); root creates the roles once and a workspace never manages its
own role.

## AWS (account 884686184019)

- Local access is the root login session, profile `tbd` (`aws login --profile tbd`). It expires; the
  aws-mcp server stops working with it. Root MFA must stay on.
- Created by hand once (root): OIDC provider `app.terraform.io` and the `tfc-*` roles. Everything else in
  the backup chain is managed by the `tbd-backups` stack: bucket `tbd-mysql-backups-884686184019` (Object
  Lock), KMS key, the uploader users and keys, OIDC provider `token.actions.githubusercontent.com`, role
  `github-actions-backup-probe`. Details: `terraform/tbd-backups/README.md`.
- Lightsail instance `platform-node` with static IP `platform-node-ip`, IPv4 only (verified: no IPv6
  address). Firewall: 443 open to Cloudflare's IPv4 ranges only (fetched from Cloudflare at plan time, so a
  Cloudflare range change reaches the firewall at the next apply of `aws-platform`), 22 only to
  `ssh_allowed_cidrs` and Lightsail's browser console. `prevent_destroy` is on: replacing the instance
  destroys the databases.
- Alerts go to SNS topics by email; each subscriber confirms once.

## Cloudflare

- `thebetterdecision.com`: managed by `terraform/cloudflare`, SSL mode Full (strict), HSTS one year.
  Traefik must serve the Cloudflare **Origin CA** certificate for every proxied hostname.
- `ziftbook.com`: the zone itself is read, not created, by Terraform, but its settings (HSTS one year,
  minimum TLS 1.2, SSL Full strict) and the proxied record `dev.ziftbook.com` are managed there. Apex and www are the Worker `ziftbook-landing`, deployed by Ziftbook CI.
- Hostnames (owner ruling 2026-10-03): staging `dev.<domain>`, production `app.<domain>`, other services
  by the same pattern (`docs.`, `blog.`). Ziftbook staging is `dev.ziftbook.com` (INFRA-47).
- The Origin CA certificate must list `thebetterdecision.com`, `*.thebetterdecision.com`, `ziftbook.com` and
  `*.ziftbook.com`; add a hostname for any new domain before proxying it.
- Mail: Mailgun EU for every app and environment (owner ruling 2026-10-03). All dev/staging environments share one
  sending domain, `m.fjconsulting.dev` (zone `fjconsulting.dev`, read but not managed by `terraform/cloudflare`, which
  owns only the `m.` records: MX, SPF, DKIM `mta._domainkey.m`, DMARC with Mailgun reporting, tracking, same set as TBD). Each dev environment has its own
  send-only sending key scoped to that domain. Production gets per-app `m.<appdomain>` domains (TBD:
  `m.thebetterdecision.com`). The domain and the keys are made by hand (below). Env names `ZIF_MAILGUN_DOMAIN`,
  `ZIF_MAILGUN_REGION`, `ZIF_MAILGUN_API_KEY`; the Ziftbook code that reads them is ZIF-151.
- Shared-domain webhooks: Mailgun delivers every dev app's events to every webhook URL registered on `m.fjconsulting.dev`,
  so an app must ignore events for messages it did not send (apps tag their messages; handled in the ZIF tickets).
- Origin CA expiry is chosen when the cert is issued: read it under SSL/TLS > Origin Server.

## DigitalOcean (rollback target until INFRA-49)

State left by the INFRA-48 cutover window, all by hand. Undo it only to roll back
([tbd-cutover.md, R1](tbd-cutover.md#rollback)); INFRA-49 decommissions all of it, not before 2026-10-11.

| Item | State | Why |
|---|---|---|
| App Platform app `pfv` | Archived (Settings > Archive mode); its default domain still answers for `app.thebetterdecision.com` with the offline page | No component runs, so neither the old API nor its scheduler can act on the old data |
| tbd repo secret `DIGITALOCEAN_ACCESS_TOKEN` | Overwritten with a dummy value | The release `deploy` job pushes `.do/app.yaml`, which would restore the archived app |
| Droplet `pfv-data-01` MySQL | `super_read_only = ON`, set at runtime (a mysqld restart clears it) | The data stays exactly as dumped; the droplet's 02:00 dump to `pfv-data-01/` continues |
| Droplet Redis key `scheduler:tick:lock` | Set for 8 days | A DigitalOcean scheduler that comes back skips every tick |

## Cluster out-of-band material

| Item | Where | Notes |
|---|---|---|
| SOPS age private key | Owner's offline backup and `flux-system/sops-age` | Public key in `.sops.yaml`. Rotated once (2026-10-02). Never displayed in a shell or chat |
| `ghcr-pull` credentials | `clusters/platform/namespaces/{tbd-prod,ziftbook-staging}-ghcr-pull.secret.yaml` | GHCR read credential; expires with the token behind it |
| NetBird | Policy `owner-to-k3s-api` (owner devices to TCP 6443), setup key `platform-node` (7-day expiry, stored as Secret `netbird-setup-key`), kubeconfig `~/.kube/platform` | `owner-admin` token expires about 2026-12-31. Runbook: [`netbird/README.md`](../clusters/platform/netbird/README.md) |
| Postgres roles for Ziftbook | Job `ziftbook-bootstrap` in `data`, from a pinned commit of the Ziftbook repo (sha256 checked) | The `ziftbook` database and roles are staging only. A rotated password also goes into `clusters/platform/ziftbook-staging/ziftbook.secret.yaml` |
| Backup upload key | Secret `data/backup-s3` | Access key of IAM user `k3s-backup-uploader` (from the `tbd-backups` stack); rotate per `terraform/tbd-backups/README.md` and re-encrypt |
| TBD app secret | `tbd-prod/tbd` (to be written as `clusters/platform/tbd-prod/tbd.secret.yaml`, INFRA-48) | Values come from the DigitalOcean app (same keys as today, or logins and encrypted columns break). Keys: the `secretKeyRef` entries in `tbd-prod/backend.yaml` (`ai-credential-encryption-key-prev` is optional). Deployments there stay at replicas 0 until cutover |
| Mailgun domain `m.fjconsulting.dev` (EU, shared by all dev environments) | Mailgun dashboard > Sending > Domains; DNS in `terraform/cloudflare`; one sending key per environment (`ziftbook-staging`, later TBD staging) | Key `api-key` of Secret `ziftbook-mailgun` (`clusters/platform/ziftbook-staging/ziftbook-mailgun.secret.yaml`, a whole new file each time, so only the public SOPS key is needed); the worker reads it as optional. Rotate: create a new key in Mailgun, regenerate the file, restart `deploy/worker`, delete the old key |
| Flux | GitRepository `flux-system`, public GitHub over HTTPS, no deploy key | Interval 1 minute, Kustomization 10 minutes, `prune: true`, no health checks |

## Jira

Project `INFRA` on the `fjconsulting.atlassian.net` site, board 70, one-week sprints. The Atlassian GitHub
integration links PRs by key in the branch name or title. Smart commits (`KEY-nn #comment ...`) go in the
commit body only.

## Expiries and rotation

| What | When | Rotation |
|---|---|---|
| `GHCR_READ_TOKEN` (Mend) | about 2026-12-31 | Mend section |
| `ghcr-pull` credentials | with their token | Cluster section |
| NetBird `owner-admin` token | about 2026-12-31 | NetBird runbook |
| Origin CA certificates (one per zone: thebetterdecision.com, ziftbook.com) | see Cloudflare dashboard of each zone | Issue, re-encrypt `origin-cert.secret.yaml` or `origin-cert-ziftbook.secret.yaml` (namespace `kube-system`), push |
| `k3s-backup-uploader` access key | no expiry, rotate on suspicion | Cluster section |
| AWS credits | 2027-08-27 | README, AWS credits |
| Root `aws login` session | hours | `aws login --profile tbd` |
