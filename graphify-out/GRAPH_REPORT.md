# Graph Report - aws-infra  (2026-10-09)

## Corpus Check
- 108 files · ~79,243 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 677 nodes · 1237 edges · 42 communities (25 shown, 17 thin omitted)
- Extraction: 94% EXTRACTED · 6% INFERRED · 0% AMBIGUOUS · INFERRED: 79 edges (avg confidence: 0.84)
- Token cost: 347,445 input · 0 output

## Community Hubs (Navigation)
- Backup freshness probe
- NetBird access and observability
- Ziftbook prod workloads
- TBD backups IAM and OIDC
- Cloudflare zone stack
- CI and SOPS checks
- Backup probe tests
- Ingress path and data stores
- Python test helpers
- Post-deploy smoke tests
- Platform node and alarms
- Prod tag tests
- SOPS secret tests
- Cloudflare API tokens
- Repo guidance and architecture
- Backup chain docs
- Release drift and Renovate
- Monitoring and smoke account
- Node memory and upsize
- Infra diagram tooling
- Log retention tests
- Renovate config
- HCP Terraform and OIDC roles
- Ziftbook staging workloads
- Telemetry to Grafana Cloud
- Release promotion
- Ziftbook default-deny policies
- Log retention script
- Ziftbook IMDS egress block
- Cloudflare tokens providers
- Platform providers
- TBD default-deny policies
- TBD IMDS egress block
- Ziftbook staging ingress
- Cloudflare providers
- Bootstrap token script
- TBD backups providers
- Observability namespace
- Ziftbook backend policy
- Ziftbook default-deny (single)
- IMDS egress (single)
- Ziftbook frontend policy

## God Nodes (most connected - your core abstractions)
1. `run()` - 32 edges
2. `probe()` - 22 edges
3. `run()` - 22 edges
4. `run()` - 19 edges
5. `ProdTags` - 18 edges
6. `SopsSecrets` - 18 edges
7. `Pass` - 17 edges
8. `tbd()` - 16 edges
9. `aws_s3_bucket.backups` - 14 edges
10. `Verdicts` - 14 edges

## Surprising Connections (you probably didn't know these)
- `Fail closed into the alarm (could-not-run verdict)` --semantically_similar_to--> `Verified-set .ok upload list`  [INFERRED] [semantically similar]
  .github/workflows/backup-freshness-probe.yml → clusters/platform/data/db-backup.yaml
- `Target architecture (decided 2026-10-01)` --conceptually_related_to--> `Platform cost (~$26/month)`  [INFERRED]
  CLAUDE.md → docs/architecture.md
- `Secret data/backup-s3` --references--> `SOPS + age Kubernetes Secrets`  [EXTRACTED]
  terraform/tbd-backups/README.md → docs/architecture.md
- `Monitoring and alerts (Lightsail alarms, budget, uptime, stale backup)` --references--> `CloudFormation stack platform-node-alarms`  [INFERRED]
  docs/architecture.md → terraform/platform/README.md
- `Restoring the database dumps (runbook)` --references--> `IAM role github-actions-backup-probe (list-only)`  [INFERRED]
  clusters/platform/data/RESTORE.md → .github/workflows/backup-freshness-probe.yml

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Ziftbook staging request path** — clusters_platform_ziftbook_staging_networkpolicy_networkpolicy_frontend, clusters_platform_ziftbook_staging_networkpolicy_networkpolicy_backend [EXTRACTED 0.90]
- **Ziftbook staging request path (Cloudflare to Traefik to frontend to backend)** — clusters_platform_ziftbook_staging_ingress_ingressroute_frontend [EXTRACTED 1.00]
- **Release promotion flow: build once, staging automerge, staging-first prod PR, smoke** — docs_release_flow_build_once_retag, docs_release_flow_promote_release, docs_release_flow_staging_automerge, docs_release_flow_prod_bump_pr, docs_release_flow_check_prod_tags, docs_runbooks_post_deploy_smoke [EXTRACTED 1.00]
- **Origin lockdown: Cloudflare proxy, firewall, Origin CA, Authenticated Origin Pulls** — docs_architecture_cloudflare_proxy, docs_architecture_lightsail_firewall, docs_architecture_origin_ca_certificate, docs_runbooks_origin_pull_client_certificate, docs_architecture_traefik [INFERRED 0.85]
- **Backup chain: db-backup CronJob, put-only uploader, Object Lock bucket, KMS, freshness probe** — docs_architecture_db_backup_cronjob, terraform_tbd_backups_readme_k3s_backup_uploader, terraform_tbd_backups_readme_backup_bucket, terraform_tbd_backups_readme_kms_key, docs_architecture_backup_freshness_probe, terraform_tbd_backups_readme_backup_probe_role [EXTRACTED 1.00]
- **Nightly backup chain: dump, verify, upload, off-host freshness probe** — clusters_platform_data_db_backup_db_backup_cronjob, clusters_platform_data_db_backup_publish, clusters_platform_data_db_backup_upload_sh, clusters_platform_data_db_backup_tbd_mysql_backups_bucket, _github_workflows_backup_freshness_probe_probe_job, github_scripts_check_backup_freshness, clusters_platform_data_restore_restore_runbook [EXTRACTED 1.00]
- **Flux GitOps reconcile with SOPS decryption** — clusters_platform_flux_system_gotk_sync_gitrepository_flux_system, clusters_platform_flux_system_gotk_sync_kustomization_flux_system, clusters_platform_flux_system_gotk_components_source_controller, clusters_platform_flux_system_gotk_components_kustomize_controller, _sops_age_key, _sops_creation_rule [INFERRED 0.85]
- **Staging-first eviction: PriorityClass plus staging-class-only quotas** — clusters_platform_namespaces_ziftbook_staging_staging_priorityclass, clusters_platform_namespaces_tbd_staging_staging_class_only_quota, clusters_platform_namespaces_ziftbook_staging_staging_class_only_quota [EXTRACTED 1.00]
- **TBD prod request path: Cloudflare to Traefik (AOP, Origin CA) to frontend/backend** — clusters_platform_traefik_traefik_tlsoption_default, clusters_platform_traefik_traefik_tlsstore_default, clusters_platform_tbd_prod_ingress_ingressroute_app, clusters_platform_tbd_prod_frontend_deployment_frontend, clusters_platform_tbd_prod_backend_deployment_backend, clusters_platform_tbd_prod_backend_client_ip_header_cf_connecting_ip [INFERRED 0.85]
- **Owner kubectl access over NetBird** — clusters_platform_netbird_readme_owner_to_k3s_api_policy, clusters_platform_netbird_netbird_deployment_netbird, clusters_platform_netbird_netbird_pvc_netbird_state, clusters_platform_netbird_netbird_secret_netbird_setup_key, clusters_platform_netbird_netbird_serviceaccount_owner_admin, clusters_platform_netbird_netbird_clusterrolebinding_owner_admin [EXTRACTED 1.00]
- **tbd-prod deny-by-default NetworkPolicy set** — clusters_platform_tbd_prod_networkpolicy_networkpolicy_default_deny_ingress, clusters_platform_tbd_prod_networkpolicy_networkpolicy_frontend, clusters_platform_tbd_prod_networkpolicy_networkpolicy_backend, clusters_platform_tbd_prod_networkpolicy_networkpolicy_egress_no_imds [EXTRACTED 1.00]
- **ziftbook-prod request path: Cloudflare -> Traefik -> frontend -> backend** — concept_cloudflare_proxy, concept_traefik, clusters_platform_ziftbook_prod_ingress_frontend, clusters_platform_ziftbook_prod_frontend_frontend_service, clusters_platform_ziftbook_prod_frontend_frontend_deployment, clusters_platform_ziftbook_prod_backend_backend_service, clusters_platform_ziftbook_prod_backend_backend_deployment, clusters_platform_ziftbook_prod_networkpolicy_frontend, clusters_platform_ziftbook_prod_networkpolicy_backend [EXTRACTED 1.00]
- **ziftbook-staging request path: Cloudflare -> Traefik -> frontend -> backend** — concept_cloudflare_proxy, concept_traefik, clusters_platform_ziftbook_staging_ingress_frontend, clusters_platform_ziftbook_staging_frontend_frontend_service, clusters_platform_ziftbook_staging_frontend_frontend_deployment, clusters_platform_ziftbook_staging_backend_backend_service, clusters_platform_ziftbook_staging_backend_backend_deployment, clusters_platform_ziftbook_staging_networkpolicy_frontend, clusters_platform_ziftbook_staging_networkpolicy_backend [EXTRACTED 1.00]
- **Ziftbook processes reading the otel ConfigMap and exporting to Alloy** — clusters_platform_ziftbook_prod_otel_otel, clusters_platform_ziftbook_staging_otel_otel, clusters_platform_ziftbook_prod_backend_backend_deployment, clusters_platform_ziftbook_prod_worker_worker_deployment, clusters_platform_ziftbook_prod_backend_migrate, clusters_platform_ziftbook_prod_worker_migrate, clusters_platform_ziftbook_staging_backend_backend_deployment, clusters_platform_ziftbook_staging_worker_worker_deployment, clusters_platform_ziftbook_staging_backend_migrate, clusters_platform_ziftbook_staging_worker_migrate, concept_grafana_alloy_otlp_endpoint [EXTRACTED 1.00]

## Communities (42 total, 17 thin omitted)

### Community 0 - "Backup freshness probe"
Cohesion: 0.05
Nodes (56): Backup Freshness Probe workflow, IAM role github-actions-backup-probe (list-only), keepalive job (re-enable scheduled workflow), Per-prefix minimum dump size floors, probe job (Backup Freshness), changes job (pick namespaces touched by push), Post-deploy Smoke workflow (INFRA-114), smoke job (matrix per namespace) (+48 more)

### Community 1 - "NetBird access and observability"
Cohesion: 0.05
Nodes (55): ClusterRoleBinding owner-admin -> cluster-admin, Deployment netbird (rootless peer platform-node, hostNetwork), Namespace netbird (prune disabled, privileged PSA), PVC netbird-state, Secret netbird-setup-key (NB_SETUP_KEY), ServiceAccount owner-admin, Cluster access runbook (kubectl and Flux over NetBird), Headlamp + Flux plugin view (+47 more)

### Community 2 - "Ziftbook prod workloads"
Cohesion: 0.10
Nodes (44): staging PriorityClass, backend Deployment (ziftbook-prod), backend Service :8000 (ziftbook-prod), backend migrate init container (ziftbook-prod), frontend Deployment, Next.js (ziftbook-prod), frontend Service :3000 (ziftbook-prod), frontend IngressRoute app.ziftbook.com, backend NetworkPolicy, frontend only (ziftbook-prod) (+36 more)

### Community 3 - "TBD backups IAM and OIDC"
Cohesion: 0.09
Nodes (42): aws_iam_openid_connect_provider.github, aws_iam_openid_connect_provider.tfc, aws_iam_role.backup_probe, aws_iam_role_policy.backup_probe, aws_iam_role_policy.tfc_backups_plan, aws_iam_role_policy.tfc_backups_provisioner, aws_iam_role.tfc_backups_plan, aws_iam_role.tfc_backups_provisioner (+34 more)

### Community 4 - "Cloudflare zone stack"
Cohesion: 0.09
Nodes (40): cloudflare_authenticated_origin_pulls_certificate.app, cloudflare_authenticated_origin_pulls_settings.app, cloudflare_dns_record.fjdev_mail, cloudflare_dns_record.tbd, cloudflare_dns_record.tbd_ping, cloudflare_dns_record.ziftbook_app, cloudflare_dns_record.ziftbook_dev, cloudflare_dns_record.ziftbook_mail (+32 more)

### Community 5 - "CI and SOPS checks"
Cohesion: 0.08
Nodes (22): CI workflow, kubeconform validation of clusters/ (pinned CRDs-catalog), Kubernetes checks job, Terraform checks job (fmt, validate, tflint, python tests), age key (private key offline and in-cluster as flux-system/sops-age), SOPS creation rule (clusters/**/*.secret.yaml, data|stringData, age), Flux CRDs (GitRepository, OCIRepository, Bucket, Helm*, Kustomization), Flux v2.9.6 install manifest (source + kustomize controllers only) (+14 more)

### Community 6 - "Backup probe tests"
Cohesion: 0.12
Nodes (7): AlarmWiring, both(), listing(), night(), PerPrefix, probe(), Verdicts

### Community 7 - "Ingress path and data stores"
Cohesion: 0.09
Nodes (35): Cloudflare DNS and proxy (Full strict), data namespace NetworkPolicy (default deny), Cloudflare edge rate limit on auth endpoints (INFRA-123), Flux (source + kustomize controllers), GHCR images, Landing Workers tbd-landing and ziftbook-landing, Lightsail firewall (443 from Cloudflare only), Mailgun EU HTTP API mail standard (+27 more)

### Community 8 - "Python test helpers"
Cohesion: 0.12
Nodes (5): Drift, FailsClosed, iso(), run(), run()

### Community 9 - "Post-deploy smoke tests"
Cohesion: 0.13
Nodes (4): Alarm, issue(), Pass, run()

### Community 10 - "Platform node and alarms"
Cohesion: 0.14
Nodes (30): aws_budgets_budget.monthly, aws_cloudformation_stack.node_alarms, aws_cloudtrail.platform, aws_cloudwatch_metric_alarm.ping, aws_lightsail_instance.node, aws_lightsail_instance_public_ports.firewall, aws_lightsail_static_ip_attachment.node, aws_lightsail_static_ip.node (+22 more)

### Community 11 - "Prod tag tests"
Cohesion: 0.24
Nodes (4): img(), ProdTags, run(), tbd()

### Community 13 - "Cloudflare API tokens"
Cohesion: 0.24
Nodes (14): cloudflare_account_token.cloudflare_workspace, cloudflare_account_token.imported, data.cloudflare_account_api_token_permission_groups_list.access_write, data.tfe_workspace.cloudflare, Terraform module: terraform/cloudflare-tokens, local.access_write_ids, local.account_id, local.cloudflare_workspace_policies (+6 more)

### Community 14 - "Repo guidance and architecture"
Cohesion: 0.22
Nodes (11): aws-mcp server (account 884686184019), claude-mem-lite persistent memory, Architecture (docs/architecture.md), NetBird-only kubectl access (TCP 6443, owner-admin), Configuration map, IAM Identity Center profile fjc, Jira project INFRA, Release flow: staging, then production (+3 more)

### Community 15 - "Backup chain docs"
Cohesion: 0.27
Nodes (10): Backup freshness probe ([backup-stale] issue), CronJob db-backup (02:00 UTC), tfc-platform-plan OIDC role, S3 bucket tbd-mysql-backups-884686184019 (Object Lock GOVERNANCE), Role github-actions-backup-probe (list-only), Secret data/backup-s3, check-tbd-backups-fences.py CI check, IAM user k3s-backup-uploader (put-only) (+2 more)

### Community 16 - "Release drift and Renovate"
Cohesion: 0.24
Nodes (10): CI workflow (.github/workflows/ci.yml), Ruleset main protection (aws-infra), Mend Renovate (renovate.json rules), Release and deploy chain (10 steps), Release drift probe ([release-drift] issue), Fix forward policy, Production bump PR (automerge off), RELEASE_CONTRACT.md section 8 (INFRA-87) (+2 more)

### Community 17 - "Monitoring and smoke account"
Cohesion: 0.22
Nodes (10): Platform cost (~$26/month), Monitoring and alerts (Lightsail alarms, budget, uptime, stale backup), Route 53 health check (app.thebetterdecision.com/health/dependencies), Post-deploy smoke (INFRA-114), TBD smoke account (no MFA, TBD-371), Uptime alarm emails during a TBD deploy, AWS credits (account 884686184019), CloudWatch alarm platform-ping-unhealthy (us-east-1) (+2 more)

### Community 18 - "Node memory and upsize"
Cohesion: 0.31
Nodes (11): Lightsail node platform-node (medium_3_0, k3s), Lightsail daily snapshots (03:00 UTC), k3s GOGC=50 (INFRA-80), k3s node-name pin (/etc/rancher/k3s/config.yaml), Node memory check and upsize triggers, Upsize: snapshot to a larger bundle, aws-platform stack README, CloudTrail platform-management trail (+3 more)

### Community 19 - "Infra diagram tooling"
Cohesion: 0.18
Nodes (10): AWS Diagram MCP server (deprecated), Script-generated D2 overview of layers, Diagram drift check on graph JSON in CI, Rover, Blast Radius, Pluralith (dormant/abandoned), draw.io official MCP server, Inframap, Mermaid architecture-beta, Structurizr (C4) (+2 more)

### Community 21 - "Renovate config"
Cohesion: 0.22
Nodes (8): github>fjcloudaiconsulting/.github#v1, extends, hostRules, ignorePaths, kubernetes, managerFilePatterns, packageRules, $schema

### Community 22 - "HCP Terraform and OIDC roles"
Cohesion: 0.33
Nodes (6): HCP Terraform VCS flow (org FlamaCorp), HCP Terraform workspaces (aws-platform, cloudflare, cloudflare-tokens, tbd-backups), HashiCorp terraform-mcp-server, Genesis by root (MFA, break-glass user, roles, workspace), tfc-backups-plan OIDC role (read-only), OIDC provider app.terraform.io

### Community 23 - "Ziftbook staging workloads"
Cohesion: 0.40
Nodes (6): ziftbook-staging backend Deployment, ziftbook-staging backend Service, Secret ziftbook, ziftbook-staging frontend Deployment, ziftbook-staging worker Deployment (app.worker), Secret ziftbook-mailgun

### Community 24 - "Telemetry to Grafana Cloud"
Cohesion: 0.67
Nodes (5): Grafana Alloy DaemonSet (observability), Grafana Cloud stack, access policy and API-provisioned alerts, Memory alerts (rule group node-memory), Metrics to Grafana Cloud (Alloy) runbook, Request log retention CronJob (INFRA-130)

### Community 25 - "Release promotion"
Cohesion: 0.40
Nodes (4): GitHub App fjcloudaiconsulting-release, Tag protection rulesets (refs/tags/v*), promote-release@v1 shared workflow, release-please release PR

### Community 26 - "Ziftbook default-deny policies"
Cohesion: 0.67
Nodes (3): data/networkpolicy.yaml, default-deny-ingress NetworkPolicy (ziftbook-prod), default-deny-ingress NetworkPolicy (ziftbook-staging)

## Knowledge Gaps
- **79 isolated node(s):** `IngressRoute frontend (dev.ziftbook.com)`, `NetworkPolicy backend (admits frontend)`, `NetworkPolicy frontend (admits Traefik)`, `NetworkPolicy default-deny-ingress (ziftbook-staging)`, `NetworkPolicy egress-no-imds` (+74 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 117 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **17 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `tbd-prod Namespace` connect `Backup freshness probe` to `CI and SOPS checks`?**
  _High betweenness centrality (0.051) - this node is a cross-community bridge._
- **What connects `IngressRoute frontend (dev.ziftbook.com)`, `NetworkPolicy backend (admits frontend)`, `NetworkPolicy frontend (admits Traefik)` to the rest of the system?**
  _79 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Backup freshness probe` be split into smaller, more focused modules?**
  _Cohesion score 0.05109126984126984 - nodes in this community are weakly interconnected._
- **Why does `run()` connect `Post-deploy smoke tests` to `Python test helpers`?**
  _High betweenness centrality (0.030) - this node is a cross-community bridge._
- **Should `NetBird access and observability` be split into smaller, more focused modules?**
  _Cohesion score 0.05028248587570622 - nodes in this community are weakly interconnected._
- **Why does `Configuration map` connect `Repo guidance and architecture` to `Ziftbook prod workloads`?**
  _High betweenness centrality (0.028) - this node is a cross-community bridge._
- **Should `Ziftbook prod workloads` be split into smaller, more focused modules?**
  _Cohesion score 0.09528214616096208 - nodes in this community are weakly interconnected._