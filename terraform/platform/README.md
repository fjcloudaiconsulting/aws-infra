# `aws-platform`

Shared AWS resources for the platform in account `884686184019`, eu-central-1: today the
`platform-alerts` SNS topic, later the Lightsail node, CloudTrail and budgets.

## Roles

Two OIDC roles, documents in `aws/bootstrap/`. Neither is managed by Terraform: a workspace that
owns its own role can widen it.

- `tfc-platform-plan` (`run_phase:plan`): an explicit read allow-list for the services below
  (configuration only, no data reads such as `s3:GetObject`, logs, parameters or secrets) plus a
  Deny on Lightsail SSH/key-pair access and every path into the TBD backup chain. A speculative
  plan runs PR code, so it gets nothing beyond what refreshing this stack needs.
- `tfc-platform-apply` (`run_phase:apply`): Lightsail (eu-central-1 only), and budgets, CloudTrail trails,
  SNS topics and CloudWatch alarms named `platform-*`, `fjc-platform-*` buckets in this account, plus
  reads and IAM reads. No IAM writes. Same backup-chain Deny. Apply runs only after an approved
  merge; it can still create Lightsail key pairs or snapshots, so the node-access Deny is a
  plan-phase guarantee only.

A new resource type or data source for this stack means widening both role documents first (the
plan allow-list and the apply allow-list), then re-running the `put-role-policy` lines below.
Trust edits follow the add, apply, remove order in the repo README.

## Genesis (once, root)

Root through `aws login` or CloudShell; the account has no root access keys.

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
`fjcloudaiconsulting/aws-infra` branch `main`, working directory `terraform/platform`, trigger
prefix `terraform/platform`, Terraform 1.16.4, auto-apply off, speculative plans on. Environment
variables:

| Name | Value |
|---|---|
| `TFC_AWS_PROVIDER_AUTH` | `true` |
| `TFC_AWS_PLAN_ROLE_ARN` | `arn:aws:iam::884686184019:role/tfc-platform-plan` |
| `TFC_AWS_APPLY_ROLE_ARN` | `arn:aws:iam::884686184019:role/tfc-platform-apply` |

Never set `TFC_AWS_RUN_ROLE_ARN`: it would give unapproved PR plans the apply role.
