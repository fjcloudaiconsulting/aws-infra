# Configuration map

Settings that live **outside git**: GitHub org and repo settings, GitHub Apps, Mend Renovate, HCP
Terraform, AWS, Cloudflare, Grafana Cloud, the cluster's out-of-band secrets, Jira. They were set by hand in UIs and
consoles, so git cannot show drift and a wrong value fails silently. This page says what is set, where,
what depends on it, and how it shows when it breaks. Names only: secret values never go in this repo
(it is public).

Verified against the live settings on 2026-10-03. When you change any setting below, change this page
in the same PR or right after.

## When something breaks

| Symptom | Likely cause | Look at | Fix |
|---|---|---|---|
| Release job fails with `Resource not accessible by integration` on create-a-release | The release App token lacks `workflows`. GitHub treats a new tag as creating workflow files when a later `main` commit changed one | [Release chain](#release-and-deploy-chain) step 4, [GitHub Apps](#github-apps) | Org owner: App permissions > Workflows: Read and write, then accept on the org installation. Re-run the failed job |
| Release job fails creating the release or tag with `Repository rule violations found` (creations restricted) | The release App is missing from the repo's `tag protection` ruleset bypass list, or release-please ran with another token (`GITHUB_TOKEN` or a non-admin PAT) | [Tag protection](#tag-protection) | Ruleset `tag protection` > Bypass list > `fjcloudaiconsulting-release` (app) > Always. Re-run the failed job |
| Release job is green but `promote` and `smoke` are skipped, no tag | `main` moved on after the release PR merged ("main is at X; skipping"). Expected | The newer main run | Nothing, the newest commit's run releases it. If the newest run also skipped or failed, re-run it |
| No release PR after a merge | Only `feat`, `fix`, `perf`, `revert` and breaking commits release (Renovate's `fix(deps):` does); `chore`, `ci`, `docs`, `build`, `test`, `refactor`, `style` do not. Or the release job failed | Run of the merge commit, job `Release PR and tag` | Fix the job; a `chore` merge alone never opens one |
| Staging image bump sits on a `renovate/ziftbook-staging-*` branch and never merges, or shows up as a PR | Renovate app is not a bypass actor on the aws-infra ruleset, or CI did not run on the branch | [Rulesets](#branch-protection), `ci.yml` push filter | Ruleset > Bypass list > Renovate (app) > Always. CI must report `Terraform checks` and `Kubernetes checks` on the branch |
| No app image bumps, Dependency Dashboard lists `ghcr.io` lookup failures (other dependencies still get PRs) | `GHCR_READ_TOKEN` (Mend org secret) expired or revoked | [Mend Renovate](#mend-renovate) | New classic PAT with only `read:packages`, owned by GitHub user `flamarion` (the username is fixed in `renovate.json` hostRules); replace the Mend secret, tick "run again" on the dashboard |
| `ImagePullBackOff` in `ziftbook-staging`, `tbd-staging` or `tbd-prod` | The `ghcr-pull` credential expired or was revoked | `clusters/platform/namespaces/*-ghcr-pull.secret.yaml` | Re-encrypt a new GHCR read credential into every file (see [Cluster](#cluster-out-of-band-material)) |
| After a node replacement, `mysql-0`, `postgres-0`, `valkey-0` or `netbird` stay Pending with `volume node affinity conflict`, or `kubectl get nodes` lists a second node | k3s registered under the new instance's hostname; local-path volumes are pinned to the old node name | `kubectl get nodes`, `kubectl -n data describe pod mysql-0` (Events) | On the node: `node-name: <old name>` in `/etc/rancher/k3s/config.yaml`, `sudo systemctl restart k3s`, delete the new Node object ([runbook](runbooks.md#upsize-snapshot-to-a-larger-bundle) step 2) |
| `kubectl`/`flux` cannot connect | NetBird client not connected, or the `owner-admin` token expired | [`netbird/README.md`](../clusters/platform/netbird/README.md) | Connect NetBird; renew the token per the runbook |
| A pod or Job in `ziftbook-staging` or `tbd-staging` is never created (`FailedCreate`, "exceeded quota: staging-class-only") | Every pod there must set `priorityClassName: staging`; the quota rejects any other, Jobs and CronJobs included | `kubectl -n <ns> get events` | Add `priorityClassName: staging` and explicit memory requests that fit the `memory` quota |
| Flux shows the Kustomization Ready but a workload is down | `flux-system` has no `healthChecks`: pod, quota or PSA failures do not turn it red | `kubectl -n <ns> get pods,events` | Fix the manifest. Namespace limits: [`namespaces/ziftbook-staging.yaml`](../clusters/platform/namespaces/ziftbook-staging.yaml) |
| Flux cannot apply a `*.secret.yaml` | `flux-system/sops-age` missing or holds the wrong key | README, Kubernetes secrets | Recreate the secret from the offline key |
| TBD staging backend stuck in `Init` (migrate restarts with "Access denied" or "Unknown database") | The `tbd_staging` database or user does not exist, or its password differs from `tbd-staging/tbd` `database-url` | `kubectl -n tbd-staging logs deploy/backend -c migrate` | Rerun [MySQL database per app environment](runbooks.md#mysql-database-per-app-environment); it is idempotent and resets the password |
| TBD staging pods in `CreateContainerConfigError` | Secret `tbd-captcha` (keys `site-key`, `secret`) missing | `kubectl -n tbd-staging describe pod` | Cloudflare dashboard > Turnstile > widget `tbd-staging` (hostname `dev.thebetterdecision.com`): write its site key and secret key as keys `site-key` and `secret` of a new `tbd-staging/tbd-captcha.secret.yaml`, as in [runbooks.md](runbooks.md#write-or-rotate-a-kubernetes-secret) |
| Ziftbook staging sends no mail (once ZIF-151 ships) | Secret `ziftbook-mailgun` (key `api-key`) missing (the worker starts without it), or the Mailgun domain is not verified | `kubectl -n ziftbook-staging logs deploy/worker`, Mailgun domain status | Write `ziftbook-mailgun.secret.yaml` (INFRA-47 guide, part D), then `kubectl -n ziftbook-staging rollout restart deploy/worker` (env is read at pod start), or fix the DNS records until Mailgun shows the domain verified |
| `cloudflare` plan fails with Cloudflare `Authentication error` | Token `tf: cloudflare workspace` was deleted or rolled in the dashboard, or the variable was overwritten by hand | Workspace `cloudflare-tokens` | Start a plan and apply there: a missing token is recreated and the variable rewritten. Change token scopes only in `terraform/cloudflare-tokens` |
| Cloudflare 526 on a proxied host | Traefik serves the wrong cert: the zone's Secret (`kube-system/origin-cert` for thebetterdecision.com, `origin-cert-ziftbook` for ziftbook.com) is missing or its Origin CA cert expired | `clusters/platform/traefik/` (applied to namespace `kube-system`), Cloudflare SSL/TLS > Origin Server of that zone | Issue a new Origin CA cert in that zone, re-encrypt its `*.secret.yaml` |
| Every proxied host on the node fails at once (Cloudflare 525, or 520), right after an origin-pull change | Traefik requires our client certificate (`TLSOption default`) and Cloudflare did not present it: zone-level Authenticated Origin Pulls off or its certificate not `active`, the leaf not signed by a CA in `kube-system/origin-pull-ca-<gen>`, or a listed Secret missing (Traefik then fails closed for every host) | Cloudflare SSL/TLS > Origin Server > Authenticated Origin Pulls of each zone; `kubectl -n kube-system logs deploy/traefik` | [Runbook rollback](runbooks.md#origin-pull-client-certificate-authenticated-origin-pulls) |
| Cloudflare 429 page (error 1015) on sign-in, sign-up, password reset, MFA or an invite link | The edge rate limit (INFRA-123): more than 20 requests in 10 s from one IP to the zone's auth paths, which on ziftbook.com include `GET /api/session`. Blocks last 10 s. Many users behind one NAT share the counter | `terraform/cloudflare/rate_limit.tf`, Cloudflare Security > Analytics of the zone | Wait 10 s. If real users trip it, raise `requests_per_period` or drop a chatty path in a PR |
| A PR has no `Terraform Cloud/FlamaCorp/<ws>` check | Workspace missing, or its trigger path was not touched. Re-running GitHub checks does not trigger a plan | HCP Terraform workspace | An absent check is not a pass. Push a change under the stack's directory |
| `aws` says "session has expired", aws-mcp tools missing | Root login session expired | n/a | Owner runs `aws login --profile tbd` |
| Ziftbook Renovate PR fails `pnpm install` with `ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION` | A package version is younger than pnpm's 1 day policy | INFRA-77 | Re-run CI a day later |
| No new metrics in Grafana Cloud | Alloy pod in `CreateContainerConfigError` (Secret `observability/grafana-cloud` missing), or the exporter logs `401` (token revoked, or wrong Instance ID) | `kubectl -n observability get pods`, `kubectl -n observability logs ds/alloy` | Write the Secret per the [runbook](runbooks.md#metrics-to-grafana-cloud-alloy), then `kubectl -n observability rollout restart ds/alloy` |
| A Grafana alert is Firing (Alerting > Alert rules) but no email arrives | Contact point `owner-email` failing (its row in Alerting > Contact points shows the last error), or the mail is in spam (sender `noreply@grafana.net`) | [Grafana Cloud](#grafana-cloud) | Fix `grafana/contact-point.json` and re-apply it ([runbook](runbooks.md#memory-alerts)) |
| Alarm emails never arrive | SNS email subscriptions deliver only after the recipient confirms | AWS SNS topics `platform-alerts`, `platform-alerts-use1` | Click the confirmation link in the subscription email |
| tbd release run red at `deploy`, an undeployed-release issue opens, tbd `deploy-drift-probe` red | Expected since the INFRA-48 cutover: tbd's `DIGITALOCEAN_ACCESS_TOKEN` secret was overwritten so no release un-archives the DigitalOcean app | [DigitalOcean](#digitalocean-rollback-target-until-infra-49) | Nothing; the k3s deploy is the Renovate bump PR. tbd#840 (INFRA-44, after INFRA-49) removes the DO jobs. Never restore the token except in a rollback |

## Release and deploy chain

Every arrow depends on a setting listed in this page. The chain is proven end to end for Ziftbook
staging (v0.20.2, 2026-10-03). TBD production (`tbd-prod`, since the INFRA-48 cutover) bumps arrive as
PRs and are never automerged (proven by Renovate dry run only, check it on the first TBD bump).

The rules are [release contract section 8](https://github.com/fjcloudaiconsulting/.github/blob/main/RELEASE_CONTRACT.md#8-deploy-handoff)
(decision INFRA-87). A release is not a deploy. Staging follows `vX.Y.Z` and is fast-forwarded into
`main` without a PR (steps 6 to 9). Production is bumped by a PR the owner merges only after the same tag
runs in that app's staging. The CI check for the tag rule is INFRA-89 (not built yet); TBD gets staging in
INFRA-67 and this flow in INFRA-91. A release that fails on staging is fixed forward; marking its GitHub
release a prerelease keeps it out of the drift watch below.

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
| .github | Ruleset `main protection` (id 24298798) | PR with 1 approval (squash only), linear history, no force-push or deletion, no required checks. Bypass: org admin, repository admin role. Tags: see [Tag protection](#tag-protection) |
| app-template | Ruleset `main protection` (id 24384611) | Same as `.github`: PR with 1 approval, linear history, no required checks |
| ziftbook | Classic branch protection | 1 review, strict checks `Backend Checks`, `Frontend Checks`, `pr-title / check`, admins not enforced. **Force-push and deletion of `main` are allowed** |
| tbd | Classic branch protection | 1 review, checks `Backend Checks`, `Frontend Checks`, admins enforced |

### Tag protection

Git release tags `v*` are immutable by policy. Each repo below has a ruleset `tag protection` on
`refs/tags/v*`: restrict creations, updates and deletions, block force pushes. Only the bypass actors
can create a `v*` tag, so the release App must stay on the list of every app repo or the next release
fails at the tag (see the symptom table). The App bypass is only as strong as the `release`
environment that holds its key (`main` only, see [Per-repo settings](#per-repo-settings)) and the
`main` branch protection. These rulesets cover git refs only, not the GHCR `vX.Y.Z` image tags.

| Repo | Ruleset id | Bypass (Always) |
|---|---|---|
| .github | 24413637 (INFRA-76) | Org admin only. The owner moves `v1`; the release App is not installed here |
| tbd | 24454860 (INFRA-94, 2026-10-04) | Org admin, `fjcloudaiconsulting-release` app (id 5166919) |
| ziftbook | 24454865 (INFRA-94, 2026-10-04) | Org admin, `fjcloudaiconsulting-release` app (id 5166919) |
| app-template | 24454868 (INFRA-94, 2026-10-04) | Org admin, `fjcloudaiconsulting-release` app (id 5166919). Repos made from the template get only its files: each new app repo needs this ruleset, the App installed and the `release` environment ([Per-repo settings](#per-repo-settings)) |

### GitHub Apps

Org settings > GitHub Apps (installations). Permission changes ask the org owner to accept on the
installation, and the grant applies to **every repository in the installation**.

| App | Repos | Notes |
|---|---|---|
| `fjcloudaiconsulting-release` | selected: each app repo on the shared release flow (Ziftbook, app-template, tbd from INFRA-42) | Permissions: contents, issues, pull requests write; metadata read; **workflows write** (added 2026-10-03, INFRA-78). Private key held by the owner and stored only as the `release` environment secret. Keep `.github` and aws-infra out of the selection so this key cannot move the `v1` tag or add a workflow there (`renovate` and `claude` already hold contents and workflows write on those repos) |
| `renovate` (Mend) | selected: `.github`, aws-infra, ziftbook, tbd (added 2026-10-04, INFRA-109) | Repos are added on GitHub, not in Mend |
| `terraform-cloud`, `digitalocean`, `gitguardian`, `atlassian`, `claude`, `tbd-branch-protection-probe` | various | Not part of the release chain. `atlassian` links PRs to Jira |

### Per-repo settings

- **Environment `release`** (Ziftbook, tbd from INFRA-42; create the same in every new app repo, app-template does not ship
  it): deployment branches limited to `main`, **no required reviewers** (the job runs on every `main`
  push, a reviewer would block each one), secrets `RELEASE_APP_ID` and `RELEASE_APP_PRIVATE_KEY`.
- **Environments `tbd-prod` and `ziftbook-staging`** (aws-infra, INFRA-114): the post-deploy smoke jobs run in them.
  `tbd-prod`: deployment branches "Selected branches and tags", `main` only, no tag rule, no required reviewers;
  secrets `SMOKE_USERNAME` and `SMOKE_PASSWORD` (the [TBD smoke account](#cluster-out-of-band-material)). A missing
  secret shows as `app smoke failed` on the `[post-deploy-smoke] tbd-prod` issue. `ziftbook-staging` holds nothing (a job
  that names a missing environment creates it, without restrictions).
- **Environment `landing`** (tbd and ziftbook, INFRA-60/INFRA-98): deployment branches `main` only; secret
  `CLOUDFLARE_API_TOKEN`, a per-Worker token for that app's landing Worker. Scopes and rules:
  [Worker and Snippet access](#worker-and-snippet-access-infra-98).
- Dependabot vulnerability alerts (`gh api -i repos/<r>/vulnerability-alerts`: 204 on, 404 off): on in `.github`, aws-infra and ziftbook; **off in tbd** as of 2026-10-04 (INFRA-109, owner to enable). Renovate's security-fix PRs, which skip grouping and dashboard approval, only fire where they are on. Dependabot security updates (`repos/<r>/automated-security-fixes`) are off in all four (Renovate opens the fixes).
- Actions default workflow permission is read-only everywhere checked. "Allow GitHub Actions to create and approve pull requests" is off in aws-infra, tbd and ziftbook (turned off 2026-10-04; release-please uses the release App token, nothing approves with `GITHUB_TOKEN`). It is still on in app-template.
- `.github` hosts the contract, the reusable workflows, the Renovate preset and the weekly conformance
  probe. Apps consume them by the moving major tag `@v1`; changing a workflow means tagging a new semver
  and moving `v1` (owner approval, public contract).

### Actions secrets and variables

**Rule (owner, 2026-10-04, INFRA-99).** GitHub keeps only the secrets and variables a workflow needs to
run: CI, release and deploy credentials and deploy targets. Every value an app reads at runtime, secret or
not, lives under `clusters/` once Flux deploys the app: secrets in a SOPS-encrypted Secret, everything else
as plain `env` in the app's manifests. A runtime value found in GitHub moves there, or is deleted from GitHub
when the cluster already holds it.
Every GitHub secret or variable has a workflow on `main` that reads it; one without a reader is deleted.
The app-template README carries the same rule for new apps.

Inventory, 2026-10-04, every repo in the org (names from the API, consumers from `main`). Org level: no Actions secrets,
Actions variables or Dependabot secrets. aws-infra (until INFRA-114's `tbd-prod` environment, row below), `.github` and app-template: none at any level
(app-template's `ci.yml` reads the two `release` secrets, which each new repo sets per its checklist).
tbd and ziftbook have no repo-level Dependabot secrets; tbd's environment `copilot` and fjconsulting-website's environment `dev` hold nothing.

| Repo | Level | Name | Read by | Class | Fate |
|---|---|---|---|---|---|
| tbd | env `release` | secrets `RELEASE_APP_ID`, `RELEASE_APP_PRIVATE_KEY` | `release.yml` | pipeline | stays |
| tbd | repo | secret `GIST_TOKEN` | `test.yml` (coverage badges, `main` only) | pipeline | stays |
| tbd | repo | secret `PROTECTION_PROBE_APP_KEY`, variable `PROTECTION_PROBE_APP_ID` | `branch-protection-probe.yml` | pipeline | stays |
| tbd | repo | variables `AWS_APEX_BUCKET`, `AWS_APEX_DEPLOY_ROLE_ARN`, `AWS_APEX_DISTRIBUTION_ID`, `AWS_APEX_REGION` | `apex-deploy.yml` | pipeline (apex deploy target, older AWS account) | stay while the apex is served from S3 and CloudFront (INFRA-60 moves it to a Worker) |
| tbd | repo | secret `DIGITALOCEAN_ACCESS_TOKEN` | `deploy.yml`, `deploy-drift-probe.yml`, `release.yml` `deploy` | DigitalOcean only (holds a dummy since INFRA-48) | delete after INFRA-49, once tbd#840 (INFRA-44) removes its readers |
| tbd | repo | secrets `SMOKE_USERNAME`, `SMOKE_PASSWORD` | `deploy.yml`, `release.yml` `smoke-tests` (the DigitalOcean post-deploy smoke) | DigitalOcean path; the values already live in `tbd-prod/tbd-smoke` | delete with `DIGITALOCEAN_ACCESS_TOKEN` |
| aws-infra | env `tbd-prod` (main only) | secrets `SMOKE_USERNAME`, `SMOKE_PASSWORD` | `post-deploy-smoke.yml` (INFRA-114) | pipeline: the post-deploy smoke logs in as the smoke account; copy of `tbd-prod/tbd-smoke` | stays |
| ziftbook | env `release` | secrets `RELEASE_APP_ID`, `RELEASE_APP_PRIVATE_KEY` | `ci.yml` | pipeline | stays |
| tbd | env `landing` (main only) | secret `CLOUDFLARE_API_TOKEN` | `apex-deploy.yml` `deploy-worker` | pipeline; token `tbd-landing deploy`, adopted by workspace `cloudflare-tokens` (INFRA-133 import), value set by hand when the token was made | stays |
| ziftbook | env `landing` (main only) | secret `CLOUDFLARE_API_TOKEN` | `landing.yml` | pipeline; token `ziftbook-landing deploy`, adopted by workspace `cloudflare-tokens` (INFRA-133 import), value set by hand when the token was made | stays |
| fjconsulting-website | repo | secrets `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | `deploy.yml`, `deploy-dev.yml` | pipeline | stays |

`GHCR_READ_TOKEN` is a Mend org secret, not a GitHub one (see [Mend Renovate](#mend-renovate)). No app
runtime value is left in GitHub once the three DigitalOcean-path secrets are deleted. A new repo in the org gets its rows here.

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
  branch. `tbd-staging` has no rule of its own until INFRA-91: its bumps arrive as one PR per image, so merge
  backend and migrations together.
- Each repo has a Dependency Dashboard issue; ticking "run again" there forces a run.
- App repos (tbd, ziftbook) add repo-level rules in their own `renovate.json` (tbd#833, ziftbook#180), not in the shared preset: there they would also bundle aws-infra's platform image bumps into one docker group and put staging app-image majors behind dashboard approval, breaking the ziftbook-staging automerge. Rules: non-major updates grouped per ecosystem, FastAPI and uvicorn standalone, OpenTelemetry in its own group, npm updates wait 1 day (pnpm 12's default release age), majors and runtime upgrades only on Dependency Dashboard approval, datastore image majors off. tbd needs no `GHCR_READ_TOKEN`: it references no private `ghcr.io` image.
- Local dry run (check a config without waiting for Mend): Node 24, then `renovate --platform=local --dry-run=full` with `GITHUB_COM_TOKEN`, `RENOVATE_TOKEN` and `RENOVATE_SECRETS='{"GHCR_READ_TOKEN":"..."}'` in the environment. The local platform reads only committed files, and `local>` presets do not resolve there. `LOG_LEVEL=debug LOG_FORMAT=json` prints a `packageFiles with updates` record with each update's branch; it does not render the dashboard, so approval gates show only on the first Mend run.

## HCP Terraform

Org `FlamaCorp`. Workspaces are created in the UI or through the API with the owner's token (VCS flow, plan on PR,
apply on merge after approval in the UI). The workspace name must equal the `cloud` block name, and the `tbd-backups`
name is pinned in an AWS trust policy: never rename it.

| Workspace | Stack | Auth |
|---|---|---|
| `aws-platform` | `terraform/platform` | OIDC: env vars `TFC_AWS_PROVIDER_AUTH=true`, `TFC_AWS_PLAN_ROLE_ARN`, `TFC_AWS_APPLY_ROLE_ARN`. Optional variable `ssh_allowed_cidrs` is unset: port 22 is reachable only from the Lightsail browser console |
| `cloudflare` | `terraform/cloudflare` | Sensitive env var `CLOUDFLARE_API_TOKEN`, written by `cloudflare-tokens` (token `tf: cloudflare workspace`; its scopes are `cloudflare_account_token.cloudflare_workspace` there, never edit them in the dashboard); variable `account_id`; variable `origin_pull_private_key_<gen>` per certificate generation (**sensitive**; otherwise only in this workspace's state and at Cloudflare, so remote state sharing stays off) |
| `cloudflare-tokens` (INFRA-133) | `terraform/cloudflare-tokens` | Env `CLOUDFLARE_API_TOKEN` (**sensitive**): the bootstrap token, the one hand-made Cloudflare token (account-owned, Account API Tokens: Edit only, stored by the owner with a script that checks it first). It can mint any token, so treat it as account admin: only this workspace holds it, and the workspace does not manage it. Env `TFE_TOKEN` (**sensitive**): token of team `cloudflare-tokens`, custom access on workspace `cloudflare` only (variables write, runs read). Its state holds the value of every token it creates: remote state sharing off, destroy plans off, auto-apply off. Any in-repo branch whose PR touches `terraform/cloudflare-tokens/**` plans with these credentials (a `data "external"` there could read them), so only the owner and his agents push there, and Renovate needs dashboard approval for it; HCP Terraform never plans fork PRs |
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

- `thebetterdecision.com`: managed by `terraform/cloudflare`, SSL mode Full (strict), HSTS one year. Proxied to the
  node: `ping` and `app` (TBD production since INFRA-48, a CNAME to `ping`); the rest is DNS-only.
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
- Origin pulls (INFRA-93): zone-level Authenticated Origin Pulls is on for thebetterdecision.com and ziftbook.com
  (`terraform/cloudflare/origin_pull.tf`), with one leaf certificate of our own per generation for both zones.
  Traefik's `TLSOption default` accepts only clients with a certificate signed by a CA in `kube-system/origin-pull-ca-<gen>`,
  so the node serves no one but our zones: a direct connection, or another Cloudflare account's zone pointed at the
  node, fails the TLS handshake. The Route 53 health check is unaffected because it resolves a proxied hostname, so
  it goes through Cloudflare. The CA key was discarded after signing. Procedures: [runbooks.md](runbooks.md#origin-pull-client-certificate-authenticated-origin-pulls).
- Rate limit (INFRA-123, `terraform/cloudflare/rate_limit.tf`): a new sign-in or token endpoint in either app needs its
  path added there. The zone allows one such rule (Free), managed only in Terraform. The path match relies on the
  zone's URL normalization staying on (type Cloudflare, scope incoming; a dashboard setting, not in Terraform; read
  2026-10-04 on both app zones).
- Origin CA expiry is chosen when the cert is issued: read it under SSL/TLS > Origin Server.
- API tokens (INFRA-133): every account-owned token is managed by `terraform/cloudflare-tokens` (workspace
  `cloudflare-tokens`), except the bootstrap token that workspace runs with. Change a scope there, never in the
  dashboard: the next plan shows a hand edit as drift and the apply reverts it. User tokens (My Profile > API Tokens)
  are out of reach: an account-owned token cannot read or manage them. After the cutover no automation uses one.
  Procedures: [runbooks.md](runbooks.md#cloudflare-api-tokens).

### Worker and Snippet access (INFRA-98)

AOP proves the zone, not the code. A Worker or Snippet that runs on thebetterdecision.com or ziftbook.com can set
`x-real-ip` on a subrequest to a hostname of the **same zone**, and Cloudflare forwards it to the node as
`CF-Connecting-IP`, which TBD trusts (rate limiting, `audit_events.ip_address`). A Worker on another zone or on
workers.dev cannot: Cloudflare replaces the value on cross-zone subrequests. Node hostnames (proxied to the node's
static IP): `ping.thebetterdecision.com`, `app.thebetterdecision.com`, `dev.ziftbook.com`.

Read 2026-10-04 (API, read-only), all four zones of the account (thebetterdecision.com, ziftbook.com,
fjconsulting.dev, yetanothergrower.com): no Workers routes, no Snippets, no snippet rules. Workers custom domains:
ziftbook.com and www.ziftbook.com, both `ziftbook-landing`. One Worker script, `ziftbook-landing`, which makes no
outbound fetch (only its assets binding). One Pages project, `fjconsulting-website-dev` on fjconsulting.dev (no node
hostname in that zone). One account member, the owner (Super Administrator).

Who can put code on a zone (a Pages project with a custom domain on an app zone counts the same as a Worker).
Scopes are what the dashboard shows (names only), as of 2026-10-05:

| Principal | Held in | Can do today | Scopes |
|---|---|---|---|
| Owner | dashboard, `wrangler login` | everything | Super Administrator |
| Bootstrap token (INFRA-133) | HCP Terraform workspace `cloudflare-tokens`, env var `CLOUDFLARE_API_TOKEN`; that workspace's PR plans run provider code with it | mints, edits and deletes any account-owned token, so indirectly everything | Account API Tokens Write only. The only hand-made Cloudflare token |
| `cloudflare` workspace token | HCP Terraform, env var `CLOUDFLARE_API_TOKEN`; every PR plan runs provider code with it | whatever its policies allow; Terraform manages no Worker, route, Snippet or Pages project | `tf: cloudflare workspace`, made by `cloudflare-tokens` (INFRA-133; policies in `terraform/cloudflare-tokens/main.tf`): thebetterdecision.com: Zone Write, Zone Settings Write, DNS Write, SSL and Certificates Write, Zone WAF Write; ziftbook.com: the same with Zone Read instead of Zone Write; fjconsulting.dev: Zone Read, DNS Write; account: Notifications Write. No other zone, no Workers Scripts or Workers Routes, so it cannot add a Worker route. Until the INFRA-133 cutover the hand-made user token `cloudflare-tfc` (all zones: Zone, Zone Settings, DNS Write; the two app zones: SSL and Certificates, Zone WAF Write; account: Notifications Write) is still the one in use |
| Ziftbook `CLOUDFLARE_API_TOKEN` | ziftbook `landing` environment secret, `main` only (2026-10-05; the old repo-level secret is deleted) | deploys `ziftbook-landing`; no longer touches its custom domains (ziftbook#181) | Individual Workers Editor on `ziftbook-landing` only; token `ziftbook-landing deploy`, adopted by `cloudflare-tokens` (INFRA-133 import) |
| tbd `CLOUDFLARE_API_TOKEN` (INFRA-60) | tbd `landing` environment secret, `main` only (2026-10-05) | deploys `tbd-landing` (workers.dev preview until INFRA-61) | Individual Workers Editor on `tbd-landing` only; token `tbd-landing deploy`, adopted by `cloudflare-tokens` (INFRA-133 import) |
| Cloudflare MCP OAuth grant (Claude sessions) | My Profile > Access Management > Connected Applications | full access, granted by the owner 2026-10-05 (it can deploy Workers and change zones); still 9109 on the API token lists | full |

Rules:

- A CI deploy token is an account-owned token with the **Editor** role scoped to **its one Worker**, no
  Zone > Workers Routes, no Snippets, no Pages, stored as an environment secret limited to `main`. Product-scope
  Editor (the legacy "Workers Scripts: Edit") rewrites every Worker in the account, current and future, so either
  landing token could replace the other app's landing. Zone > Workers Routes > Write on a zone can route any hostname
  of it, node hostnames included: Cloudflare tokens cannot be limited by hostname.
- Custom domains are attached by the owner (or Terraform), not by CI, and are not declared in `wrangler.jsonc`: a
  per-Worker Editor deploys an existing Worker only while the deploy does not add, change or remove a route or
  custom domain, and Custom Domains do not support per-Worker roles yet. Ziftbook stopped declaring them in ziftbook#181 (INFRA-113).
- Residual, which no token narrowing removes: a landing Worker attached to an app zone runs in that zone, so its
  code can spoof `CF-Connecting-IP` towards that zone's node hostnames. Today `ziftbook-landing` -> `dev.ziftbook.com`
  (staging); after INFRA-61 `tbd-landing` (apex and www) -> `app.thebetterdecision.com` (production). Who can change
  that code: whoever merges to the app repo's `main`, holds its deploy token, or (while the token is a plain repo
  secret) has write access to the repo. Impact: a forged IP in TBD's audit log and rate-limit buckets; the same
  token could already serve any page on the apex, which is the bigger risk. Owner decision on INFRA-98: unrecorded.
- No scheduled probe for new routes or Snippets: once the deploy tokens are per-Worker, only the owner, the
  `cloudflare` token and a write-scoped MCP grant can add one, and a probe cannot see the code-level residual above.

## Grafana Cloud

Made by hand by the owner (INFRA-85); the cluster side is `clusters/platform/observability/`. Procedures:
[runbooks.md](runbooks.md#metrics-to-grafana-cloud-alloy).

| Item | Where | Notes |
|---|---|---|
| Stack (EU region) | grafana.com Cloud Portal, the org's stack | Its OTLP endpoint (`https://otlp-gateway-prod-eu-<n>.grafana.net/otlp`) and Instance ID are keys `otlp-endpoint` and `instance-id` of Secret `observability/grafana-cloud` |
| Access policy `k3s-alloy-metrics-write` | Grafana Cloud > Administration > Cloud access policies | Realm: the stack only. Scope `metrics:write` only; add `traces:write` and `logs:write` only when Alloy starts sending them (INFRA-105, INFRA-106, INFRA-110) |
| Token `alloy-platform-node` on that policy | Key `token` of Secret `observability/grafana-cloud` (`clusters/platform/observability/grafana-cloud.secret.yaml`, a whole new file each time) | No expiry; rotate on suspicion. Write-only: it cannot read or delete data |
| Folder `Platform` (uid `platform`), contact point `owner-email`, rule group `node-memory`, dashboard `Node memory` (uid `node-memory`) | The stack (INFRA-108), applied through the Grafana API from [`grafana/`](../grafana/) | The git files are the source; rules and contact point are API-provisioned, so the UI cannot edit them; dashboard UI edits are lost on the next apply. Apply procedure and alert table: [runbook](runbooks.md#memory-alerts). No service account or token is kept |

## DigitalOcean (rollback target until INFRA-49)

State left by the INFRA-48 cutover window, all by hand. Undo it only to roll back
([tbd-cutover.md, R1](tbd-cutover.md#rollback)); INFRA-49 decommissions all of it, not before 2026-10-11.

| Item | State | Why |
|---|---|---|
| App Platform app `pfv` | Archived (Settings > Archive mode); its default domain still answers for `app.thebetterdecision.com` with the offline page | No component runs, so neither the old API nor its scheduler can act on the old data |
| tbd repo secret `DIGITALOCEAN_ACCESS_TOKEN` | Overwritten with a dummy value; the real token deleted in DO > API > Tokens | The release `deploy` job pushes `.do/app.yaml`, which would restore the archived app. A rollback mints a new token scoped to app read and update |
| Droplet `pfv-data-01` MySQL | `super_read_only = ON`, set at runtime as root (`mysql --no-defaults`; a mysqld restart clears it) | The data stays exactly as dumped; the droplet's 02:00 dump to `pfv-data-01/` continues |
| Droplet Redis key `scheduler:tick:lock` | Set for 8 days | A DigitalOcean scheduler that comes back skips every tick |

## Cluster out-of-band material

| Item | Where | Notes |
|---|---|---|
| SOPS age private key | Owner's offline backup and `flux-system/sops-age` | Public key in `.sops.yaml`. Rotated once (2026-10-02). Never displayed in a shell or chat |
| `ghcr-pull` credentials | `clusters/platform/namespaces/{tbd-prod,tbd-staging,ziftbook-staging}-ghcr-pull.secret.yaml` | GHCR read credential, the same in every namespace; expires with the token behind it |
| MySQL database and user for TBD staging | `tbd_staging` and `'tbd_staging'@'%'` in `data/mysql`, created by hand ([runbook](runbooks.md#mysql-database-per-app-environment), INFRA-67) | ALL on `tbd_staging` only, `MAX_USER_CONNECTIONS 20`. Its password is the one in `tbd-staging/tbd` `database-url`. The nightly grants dump carries the user, so a restore brings it back; the database itself is dumped once the `tbd-staging-mysql` set exists (INFRA-67 backup PRs) |
| TBD staging secrets | `tbd-staging/tbd` (generated for staging, no production value), `tbd-staging/tbd-captcha` (Turnstile widget `tbd-staging`, hostname `dev.thebetterdecision.com` only, Cloudflare dashboard > Turnstile), `tbd-staging/tbd-mailgun` (optional) | Each is a whole new file, so only the public SOPS key is needed. A new `tbd` file means new JWT and encryption keys: staging users log in again and lose MFA and AI credentials |
| NetBird | Policy `owner-to-k3s-api` (owner devices to TCP 6443), setup key `platform-node` (7-day expiry, stored as Secret `netbird-setup-key`), kubeconfig `~/.kube/platform` | `owner-admin` token expires about 2026-12-31. Runbook: [`netbird/README.md`](../clusters/platform/netbird/README.md) |
| Postgres roles for Ziftbook | Job `ziftbook-bootstrap` in `data`, from a pinned commit of the Ziftbook repo (sha256 checked) | The `ziftbook` database and roles are staging only. A rotated password also goes into `clusters/platform/ziftbook-staging/ziftbook.secret.yaml` |
| Backup upload key | Secret `data/backup-s3` | Access key of IAM user `k3s-backup-uploader` (from the `tbd-backups` stack); rotate per `terraform/tbd-backups/README.md` and re-encrypt |
| TBD app secret | `tbd-prod/tbd`, `clusters/platform/tbd-prod/tbd.secret.yaml` (INFRA-48) | Values come from the DigitalOcean app (same values, or logins and encrypted columns break); `database-url` and `redis-url` are built from the `data/mysql` and `data/valkey` Secrets. Keys: the `secretKeyRef` entries in `tbd-prod/backend.yaml` (`ai-credential-encryption-key-prev` is optional). A whole new file each time, so only the public key is needed: procedure in [tbd-cutover.md](tbd-cutover.md#1-write-the-tbd-secret-owner-before-the-rehearsal-about-30-minutes), which also checks it by fingerprint against DigitalOcean. A rotated MySQL app or Valkey password must be written here too |
| TBD smoke account | `tbd-prod/tbd-smoke`, `clusters/platform/tbd-prod/tbd-smoke.secret.yaml` (INFRA-48), aws-infra environment `tbd-prod` secrets `SMOKE_USERNAME` / `SMOKE_PASSWORD` (the post-deploy smoke, INFRA-114), and tbd Actions secrets of the same names until INFRA-99 deletes them after INFRA-49 ([Actions secrets](#actions-secrets-and-variables)) | Production user for `scripts/smoke-test.sh`: active, email verified, no MFA (TBD-371). Every store must hold the same values; the cluster copy is the readable one. Rotation and manual run: [runbooks.md](runbooks.md#tbd-smoke-account). Rotated 2026-10-04 |
| Mailgun domain `m.fjconsulting.dev` (EU, shared by all dev environments) | Mailgun dashboard > Sending > Domains; DNS in `terraform/cloudflare`; one sending key per environment (`ziftbook-staging`, `tbd-staging`) | Key `api-key` of Secret `ziftbook-mailgun` (`clusters/platform/ziftbook-staging/ziftbook-mailgun.secret.yaml`, a whole new file each time, so only the public SOPS key is needed); the worker reads it as optional. Rotate: create a new key in Mailgun, regenerate the file, restart `deploy/worker`, delete the old key |
| k3s node name (after an upsize) | `node-name:` in `/etc/rancher/k3s/config.yaml` on the node, added by hand in [the upsize runbook](runbooks.md#upsize-snapshot-to-a-larger-bundle) step 2; `node-init.sh.tftpl` does not write it | Keeps the old name (`ip-172-26-3-190`) on a new instance, since every local-path volume is pinned to it. Configuration management (INFRA-64) must keep it |
| k3s `GOGC=50` | `GOGC=50` in `/etc/systemd/system/k3s.service.env` on the node, set by hand 2026-10-04 (INFRA-80); `node-init.sh.tftpl` does not write it | Lowers the k3s process from about 846Mi to about 625Mi RSS for a little CPU. It survives k3s restarts and the snapshot upsize (same disk). A k3s upgrade by re-running the install script rewrites that file and drops it, and a node rebuilt from the launch script never has it: set it again after either. Check: `kubectl get --raw /metrics \| grep '^go_gc_gogc_percent'` shows 50. Configuration management (INFRA-64) must keep it |
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
| Origin pull client certificate, generation 1 (one leaf for both zones) and its CA (INFRA-93) | leaf 2036-10-01, CA 10 days later (`openssl x509 -in terraform/cloudflare/origin-pull/1.crt -noout -enddate`). Cloudflare emails 30 and 14 days before (`cloudflare_notification_policy.origin_pull_expiry`) | New CA and leaf, Traefik trusts both during the swap: [runbook](runbooks.md#origin-pull-client-certificate-authenticated-origin-pulls) |
| `k3s-backup-uploader` access key | no expiry, rotate on suspicion | Cluster section |
| Grafana Cloud token `alloy-platform-node` | no expiry, rotate on suspicion | Grafana Cloud section |
| Cloudflare account-owned tokens (all managed by `cloudflare-tokens`) | per token; `expires_on` in `terraform/cloudflare-tokens` | [runbook](runbooks.md#cloudflare-api-tokens). A token Terraform made gets a replace run, its consumer is rewritten in the same apply; an imported one needs its consumer wired in Terraform first |
| Cloudflare bootstrap token, HCP Terraform team token `cloudflare-tokens` | no expiry, rotate on suspicion | [runbook](runbooks.md#cloudflare-api-tokens) |
| AWS credits | 2027-08-27 | README, AWS credits |
| Root `aws login` session | hours | `aws login --profile tbd` |
