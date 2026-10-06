# Graph Report - aws-infra  (2026-10-04)

## Corpus Check
- 24 files · ~66,799 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 508 nodes · 881 edges · 28 communities (18 shown, 10 thin omitted)
- Extraction: 95% EXTRACTED · 5% INFERRED · 0% AMBIGUOUS · INFERRED: 46 edges (avg confidence: 0.89)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- TBD apex stack
- TBD backups IAM and OIDC
- CI and SOPS checks
- TBD cutover and DR
- DB backup CronJob
- Network policies and bootstrap
- Backup freshness probe tests
- Platform node and alarms
- Cloudflare DNS and origin pulls
- SOPS secret check tests
- Release drift tests
- Configuration map
- NetBird cluster access
- Flux install
- DNS diff gate
- Terraform diagram research
- Repo README overview
- Release drift probe
- tbd-apex provider locks
- platform provider locks
- Ziftbook staging ingress
- Backup freshness script
- Backup stale notifier
- cloudflare provider locks
- tbd-backups provider locks
- Backend network policy
- Frontend network policy

## God Nodes (most connected - your core abstractions)
1. `aws_cloudfront_distribution.apex` - 24 edges
2. `probe()` - 19 edges
3. `SopsSecrets` - 18 edges
4. `run()` - 16 edges
5. `aws_s3_bucket.apex` - 15 edges
6. `var.domain` - 15 edges
7. `aws_s3_bucket.backups` - 14 edges
8. `Verdicts` - 12 edges
9. `listing()` - 10 edges
10. `aws_s3_bucket.apex_logs` - 9 edges

## Surprising Connections (you probably didn't know these)
- `Lightsail firewall 443 from Cloudflare only` --semantically_similar_to--> `Authenticated Origin Pulls mTLS (INFRA-93)`  [INFERRED] [semantically similar]
  terraform/platform/README.md → CLAUDE.md
- `GHCR images and ghcr-pull secret` --references--> `Namespace tbd-prod`  [EXTRACTED]
  docs/architecture.md → clusters/platform/namespaces/tbd-prod.yaml
- `Namespace tbd-prod` --references--> `Valkey 8 sessions`  [EXTRACTED]
  clusters/platform/namespaces/tbd-prod.yaml → docs/architecture.md
- `Origin pull client certificate procedure` --references--> `Authenticated Origin Pulls mTLS (INFRA-93)`  [EXTRACTED]
  docs/runbooks.md → CLAUDE.md
- `CronJob db-backup 02:00 UTC` --conceptually_related_to--> `Backup freshness verdict logic`  [INFERRED]
  docs/architecture.md → .github/workflows/backup-freshness-probe.yml

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Owner kubectl access over NetBird** — clusters_platform_netbird_netbird_deployment_netbird, clusters_platform_netbird_README_policy_owner_to_k3s_api, clusters_platform_netbird_netbird_serviceaccount_owner_admin, clusters_platform_netbird_netbird_clusterrolebinding_owner_admin, clusters_platform_netbird_netbird_secret_netbird_setup_key [EXTRACTED 0.90]
- **Ziftbook staging request path** — clusters_platform_data_postgres_service_postgres, clusters_platform_ziftbook_staging_networkpolicy_networkpolicy_frontend, clusters_platform_ziftbook_staging_networkpolicy_networkpolicy_backend [EXTRACTED 0.90]
- **tbd-prod deny-by-default ingress: Traefik to frontend and backend, frontend to backend** — clusters_platform_tbd_prod_networkpolicy_networkpolicy_default_deny_ingress, clusters_platform_tbd_prod_networkpolicy_networkpolicy_frontend, clusters_platform_tbd_prod_networkpolicy_networkpolicy_backend [EXTRACTED 1.00]
- **Ziftbook staging request path (Cloudflare to Traefik to frontend to backend)** — clusters_platform_ziftbook_staging_ingress_ingressroute_frontend [EXTRACTED 1.00]
- **Nightly DB backup pipeline** — clusters_platform_data_db_backup_cronjob, clusters_platform_data_db_backup_mysql_dump, clusters_platform_data_db_backup_pg_dump, clusters_platform_data_db_backup_upload, clusters_platform_data_restore_backup_bucket [EXTRACTED 1.00]
- **TBD prod request path** — clusters_platform_tbd_prod_ingress_ingressroute, clusters_platform_tbd_prod_frontend_service, clusters_platform_tbd_prod_backend_service, clusters_platform_data_mysql_service [INFERRED 0.85]
- **Backup chain** — db_backup_cronjob, backup_bucket, freshness_check, stale_issue [EXTRACTED 1.00]
- **Origin lockdown layers** — lightsail_firewall, origin_pull_mtls, traefik_origin_ca, cloudflare_proxy [EXTRACTED 1.00]

## Communities (28 total, 10 thin omitted)

### Community 0 - "TBD apex stack"
Cohesion: 0.06
Nodes (75): aws_acm_certificate.apex, aws_acm_certificate_validation.apex, aws_cloudfront_distribution.apex, aws_cloudfront_function.viewer_request, aws_cloudfront_origin_access_control.apex, aws_cloudfront_response_headers_policy.apex, aws_iam_openid_connect_provider.github, aws_iam_openid_connect_provider.tfc (+67 more)

### Community 1 - "TBD backups IAM and OIDC"
Cohesion: 0.07
Nodes (51): aws_iam_access_key.uploader, aws_iam_openid_connect_provider.github, aws_iam_openid_connect_provider.tfc, aws_iam_role.backup_probe, aws_iam_role_policy.backup_probe, aws_iam_role_policy.tfc_backups_plan, aws_iam_role_policy.tfc_backups_provisioner, aws_iam_role.tfc_backups_plan (+43 more)

### Community 2 - "CI and SOPS checks"
Cohesion: 0.05
Nodes (39): CI workflow, Kubernetes checks job (SOPS check, kubeconform), CI push filter for renovate/ziftbook-staging-** branches (INFRA-36), Terraform checks job (fmt, fences, python tests, validate, tflint), .sops.yaml creation rule (age, clusters/*.secret.yaml), age private key (offline and flux-system/sops-age), main(), problems() (+31 more)

### Community 3 - "TBD cutover and DR"
Cohesion: 0.09
Nodes (37): Object Lock S3 bucket tbd-mysql-backups plus KMS, Namespace tbd-prod, Cloudflare proxy (Full strict), Cutover rollback via revert of DNS PR, Namespace data, CronJob db-backup 02:00 UTC, DigitalOcean rollback target (INFRA-49), Architecture doc (+29 more)

### Community 4 - "DB backup CronJob"
Cohesion: 0.08
Nodes (37): Secret backup-s3 (k3s-backup-uploader), common.sh publish helper, db-backup scripts ConfigMap, db-backup CronJob (02:00 UTC), mysql-dump.sh / mysql-dump init container, pg-dump.sh / pg-dump init container, postgres Service / StatefulSet (data ns, Postgres 18), upload.sh / upload container (aws-cli) (+29 more)

### Community 5 - "Network policies and bootstrap"
Cohesion: 0.07
Nodes (34): NetworkPolicies default-deny + egress-no-imds, NetworkPolicy default-deny-ingress (data), NetworkPolicy mysql (data), NetworkPolicy postgres (data), NetworkPolicy valkey (data), ziftbook backend/migrations/bootstrap.sql (pinned commit, sha256 checked), Job ziftbook-bootstrap, Secret postgres (admin, ziftbook-migrate, ziftbook-app passwords) (+26 more)

### Community 6 - "Backup freshness probe tests"
Cohesion: 0.12
Nodes (9): datetime, AlarmWiring, all_three(), listing(), night(), PerPrefix, probe(), Backup freshness probe: verdicts and alarm wiring (ported from tbd, INFRA-20).… (+1 more)

### Community 7 - "Platform node and alarms"
Cohesion: 0.14
Nodes (30): aws_budgets_budget.monthly, aws_cloudformation_stack.node_alarms, aws_cloudtrail.platform, aws_cloudwatch_metric_alarm.ping, aws_lightsail_instance.node, aws_lightsail_instance_public_ports.firewall, aws_lightsail_static_ip_attachment.node, aws_lightsail_static_ip.node (+22 more)

### Community 8 - "Cloudflare DNS and origin pulls"
Cohesion: 0.14
Nodes (27): cloudflare_authenticated_origin_pulls_certificate.app, cloudflare_authenticated_origin_pulls_settings.app, cloudflare_dns_record.fjdev_mail, cloudflare_dns_record.tbd, cloudflare_dns_record.tbd_ping, cloudflare_dns_record.ziftbook_dev, cloudflare_notification_policy.origin_pull_expiry, cloudflare_zone_setting.app (+19 more)

### Community 10 - "Release drift tests"
Cohesion: 0.22
Nodes (4): Drift, FailsClosed, tags: image tags written to clusters/ (one image each); files overrides the raw…, run()

### Community 11 - "Configuration map"
Cohesion: 0.12
Nodes (16): terraform/cloudflare stack, Out-of-git settings with symptom table, Configuration map, GHCR images and ghcr-pull secret, tfc-platform-plan and tfc-platform-apply OIDC roles, github>fjcloudaiconsulting/.github#v1, Release and deploy chain, extends (+8 more)

### Community 12 - "NetBird cluster access"
Cohesion: 0.25
Nodes (11): Deployment netbird (hostNetwork, rootless), NetBird policy owner-to-k3s-api (TCP 6443, one way), Cluster access runbook (kubectl and Flux over NetBird), ServiceAccount owner-admin, ClusterRole cluster-admin, ClusterRoleBinding owner-admin, Deployment netbird (hostNetwork, rootless), Namespace netbird (+3 more)

### Community 13 - "Flux install"
Cohesion: 0.28
Nodes (9): Flux install manifest (generated), Flux CRDs (7: source and kustomize toolkit kinds), Deployment kustomize-controller, Deployment source-controller, GitRepository flux-system (fjcloudaiconsulting/aws-infra, main), Kustomization flux-system (./clusters/platform, prune, SOPS), Secret sops-age (decryption key ref), flux-system kustomization.yaml (+1 more)

### Community 14 - "DNS diff gate"
Cohesion: 0.39
Nodes (7): DNS diff workflow (Route 53 vs Cloudflare), INFRA-15 gate before registrar NS switch, bad(), ipre(), ok(), q(), dns-diff.sh script

### Community 15 - "Terraform diagram research"
Cohesion: 0.33
Nodes (7): Visual documentation for a layered Terraform monorepo (research report), Script-generated D2 overview of cross-layer remote-state edges, draw.io MCP for curated diagrams, Regenerate in CI and diff graph JSON to detect diagram drift, Inframap (state-based fallback), terraform-docs inject mode, TerraVision per-layer diagrams from plan JSON (primary recommendation)

### Community 16 - "Repo README overview"
Cohesion: 0.33
Nodes (5): AWS credits (account 884686184019), NetBird owner access, SOPS + age secrets, Kubernetes secrets: *.secret.yaml SOPS-encrypted, Flux decrypts via flux-system/sops-age, Terraform stacks, one HCP Terraform workspace each

### Community 17 - "Release drift probe"
Cohesion: 0.50
Nodes (3): Release drift probe (INFRA-38), check-release-drift.sh script, Release Drift Probe workflow

### Community 18 - "tbd-apex provider locks"
Cohesion: 0.50
Nodes (3): provider.registry.terraform.io/hashicorp/aws, provider.registry.terraform.io/hashicorp/time, provider.registry.terraform.io/hashicorp/tls

## Knowledge Gaps
- **67 isolated node(s):** `provider.registry.terraform.io/cloudflare/cloudflare`, `provider.registry.terraform.io/hashicorp/http`, `provider.registry.terraform.io/hashicorp/aws`, `provider.registry.terraform.io/hashicorp/time`, `provider.registry.terraform.io/hashicorp/tls` (+62 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 99 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **10 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Namespace tbd-prod` connect `TBD cutover and DR` to `Configuration map`, `Network policies and bootstrap`?**
  _High betweenness centrality (0.019) - this node is a cross-community bridge._
- **Why does `Namespace tbd-prod (Pod Security restricted)` connect `Network policies and bootstrap` to `TBD cutover and DR`?**
  _High betweenness centrality (0.017) - this node is a cross-community bridge._
- **Why does `SopsSecrets` connect `SOPS secret check tests` to `CI and SOPS checks`?**
  _High betweenness centrality (0.013) - this node is a cross-community bridge._
- **What connects `provider.registry.terraform.io/cloudflare/cloudflare`, `provider.registry.terraform.io/hashicorp/http`, `provider.registry.terraform.io/hashicorp/aws` to the rest of the system?**
  _67 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `TBD apex stack` be split into smaller, more focused modules?**
  _Cohesion score 0.06234177215189873 - nodes in this community are weakly interconnected._
- **Should `TBD backups IAM and OIDC` be split into smaller, more focused modules?**
  _Cohesion score 0.07467532467532467 - nodes in this community are weakly interconnected._
- **Should `CI and SOPS checks` be split into smaller, more focused modules?**
  _Cohesion score 0.0549645390070922 - nodes in this community are weakly interconnected._