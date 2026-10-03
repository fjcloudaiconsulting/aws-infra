# `aws-platform`

Shared AWS resources for the platform in account `884686184019`, eu-central-1: today the
`platform-alerts` SNS topic (email to the owner), the `platform-monthly` budget ($50, gross of
credits; alerts at $25, $50 and forecast $50), the multi-region `platform-management` trail into
`fjc-platform-cloudtrail-884686184019` (365-day expiry), and the k3s node `platform-node` (Lightsail
`medium_3_0`, IPv4 only, static IP, daily snapshots, 443 from Cloudflare only, 22 via the Lightsail
console or `ssh_allowed_cidrs`), and its burst-credit and status-check alarms (CloudFormation stack
`platform-node-alarms`: Lightsail alarms have no Terraform resource, and they email a Lightsail
contact method that the owner verifies once through the link AWS sends). The node's launch script
(`node-init.sh.tftpl`) runs only at first boot; `user_data` changes are ignored afterwards, and
`prevent_destroy` blocks a replace.

The external uptime check (INFRA-26) is a Route 53 HTTPS health check on
`https://app.thebetterdecision.com/health/dependencies` (TBD through Cloudflare, since the INFRA-48 cutover;
`ping.thebetterdecision.com/ping`, which Traefik answers itself, before), 30 s
interval, failure threshold 3, about $2.75/month (non-AWS endpoint $0.75 plus $2 for HTTPS; no
string matching, which would add $2). Its metric exists only in us-east-1, so the alarm
`platform-ping-unhealthy` and its topic `platform-alerts-use1` (email to the owner) live there:
two unhealthy minutes, or missing data, alarm; recovery sends OK. Since INFRA-48 a TBD release or a MySQL or Valkey
restart longer than about 2 to 3 minutes sends ALARM then OK on purpose ([docs/runbooks.md](../../docs/runbooks.md#uptime-alarm-emails-during-a-tbd-deploy)).

## Roles

Two OIDC roles, documents in `aws/bootstrap/`. Neither is managed by Terraform: a workspace that
owns its own role can widen it.

- `tfc-platform-plan` (`run_phase:plan`): an explicit read allow-list for the services below plus
  `DescribeStacks`/`GetTemplate` on `platform-*` CloudFormation stacks and health-check reads (configuration only, no data
  reads such as `s3:GetObject`, logs, parameters or secrets) plus a Deny on Lightsail SSH/key-pair
  access and every path into the TBD backup chain. A speculative plan runs PR code, so it gets
  nothing beyond what refreshing this stack needs.
- `tfc-platform-apply` (`run_phase:apply`): Lightsail (eu-central-1 only), Route 53 health checks
  (they have IDs, not names, so any health check; no hosted-zone or record actions), and budgets,
  CloudTrail trails, SNS topics, CloudWatch alarms and CloudFormation stacks named `platform-*` (the stack runs
  under this role's credentials, so its Lightsail alarms fall under the Lightsail grant),
  `fjc-platform-*` buckets in this account, plus reads and IAM reads. No IAM writes. Same
  backup-chain Deny. KMS: `GenerateDataKey`/`Decrypt` only on the AWS-managed `aws/lightsail` key
  and only through Lightsail (`kms:ViaService`; Lightsail uses it when it creates instances and
  static IPs), no other key use and no key management. Apply runs only after an approved merge; it
  can still create Lightsail key pairs or snapshots, so the node-access Deny is a plan-phase
  guarantee only.

A new resource type or data source for this stack means widening both role documents first (the
plan allow-list and the apply allow-list), then re-running the `put-role-policy` lines below.
Trust edits follow the add, apply, remove order in the repo README.

## Genesis (once, root)

Root through `aws login` or CloudShell (the account has no root access keys), from a checkout of the
PR branch (`main` once merged), or with the four `aws/bootstrap/tfc-platform-*.json` files uploaded.

```bash
cd aws/bootstrap
aws iam create-role --role-name tfc-platform-plan \
  --assume-role-policy-document file://tfc-platform-plan-trust.json
aws iam put-role-policy --role-name tfc-platform-plan \
  --policy-name tfc-platform-plan --policy-document file://tfc-platform-plan.json

aws iam create-role --role-name tfc-platform-apply \
  --assume-role-policy-document file://tfc-platform-apply-trust.json
aws iam put-role-policy --role-name tfc-platform-apply \
  --policy-name tfc-platform-apply --policy-document file://tfc-platform-apply.json
```

HCP Terraform workspace `aws-platform` (org FlamaCorp, same project as the other workspaces): VCS
`fjcloudaiconsulting/aws-infra` branch `main`, working directory `terraform/platform`, VCS
trigger "Only trigger runs when files in specified paths change" with the pattern `terraform/platform/**`,
Terraform 1.16.4, auto-apply off, speculative plans on. Environment
variables:

| Name | Value |
|---|---|
| `TFC_AWS_PROVIDER_AUTH` | `true` |
| `TFC_AWS_PLAN_ROLE_ARN` | `arn:aws:iam::884686184019:role/tfc-platform-plan` |
| `TFC_AWS_APPLY_ROLE_ARN` | `arn:aws:iam::884686184019:role/tfc-platform-apply` |

Never set `TFC_AWS_RUN_ROLE_ARN`: it would give unapproved PR plans the apply role.

## Uptime check (INFRA-26)

Before merging, re-mint both role policies as root (same shell as Genesis), from this PR's branch
rebased on current `main`: other PRs edit the same documents, and a stale branch would drop their entries:

```bash
cd aws/bootstrap
aws iam put-role-policy --role-name tfc-platform-plan \
  --policy-name tfc-platform-plan --policy-document file://tfc-platform-plan.json
aws iam put-role-policy --role-name tfc-platform-apply \
  --policy-name tfc-platform-apply --policy-document file://tfc-platform-apply.json
```

Merge only after the INFRA-25 Traefik change is live and the ping URL answers:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://ping.thebetterdecision.com/ping   # 200
```

Without it the alarm fires on the first apply. After the apply, click the "AWS Notification -
Subscription Confirmation" link for `platform-alerts-use1` (a second email, separate from
`platform-alerts`), then check (profile `tbd`, a few minutes after the apply):

```bash
aws sns list-subscriptions-by-topic --profile tbd --region us-east-1 \
  --topic-arn arn:aws:sns:us-east-1:884686184019:platform-alerts-use1 \
  --query 'Subscriptions[].SubscriptionArn' --output text
# an ARN ending in a UUID, not PendingConfirmation
aws route53 get-health-check-status --profile tbd --health-check-id "$(aws route53 list-health-checks \
  --profile tbd --query "HealthChecks[?HealthCheckConfig.FullyQualifiedDomainName=='app.thebetterdecision.com'].Id" \
  --output text)" --query 'HealthCheckObservations[].StatusReport.Status' --output text
# every line starts with "Success: HTTP Status Code 200"
aws cloudwatch describe-alarms --profile tbd --region us-east-1 \
  --alarm-names platform-ping-unhealthy --query 'MetricAlarms[].StateValue' --output text
# OK
```
