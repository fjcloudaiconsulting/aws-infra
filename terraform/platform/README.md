# `aws-platform`

Shared AWS resources for the platform in account `884686184019`, eu-central-1: today the
`platform-alerts` SNS topic, later the Lightsail node, CloudTrail and budgets.

## Roles

Two OIDC roles, documents in `aws/bootstrap/`. Neither is managed by Terraform: a workspace that
owns its own role can widen it.

- `tfc-platform-plan` (`run_phase:plan`): managed `ReadOnlyAccess` plus an inline Deny. A
  speculative plan runs PR code, so the Deny removes content and secret reads (`s3:GetObject*`,
  `ssm:GetParameter*`, Secrets Manager values, KMS decrypt, Lightsail SSH/key-pair access) and every
  path into the TBD backup chain.
- `tfc-platform-apply` (`run_phase:apply`): Lightsail (eu-central-1 only), CloudTrail, Budgets, SNS,
  CloudWatch, `fjc-platform-*` buckets, IAM reads. No IAM writes. Same backup-chain Deny.

A new service for this stack means widening `tfc-platform-apply.json` first, then re-running the
`put-role-policy` line below. Trust edits follow the add, apply, remove order in the repo README.

## Genesis (once, root)

```bash
cd aws/bootstrap
aws iam create-role --role-name tfc-platform-plan \
  --assume-role-policy-document file://tfc-platform-plan-trust.json
aws iam attach-role-policy --role-name tfc-platform-plan \
  --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess
aws iam put-role-policy --role-name tfc-platform-plan \
  --policy-name tfc-platform-plan-deny --policy-document file://tfc-platform-plan-deny.json

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
