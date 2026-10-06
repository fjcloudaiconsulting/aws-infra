output "backup_s3_bucket" {
  description = "Bucket the nightly dumps go to."
  value       = aws_s3_bucket.backups.id
}

output "backup_probe_role_arn" {
  description = "Role the scheduled freshness workflow assumes via GitHub OIDC."
  value       = aws_iam_role.backup_probe.arn
}

output "tfc_provisioner_role_arn" {
  description = "Set as TFC_AWS_RUN_ROLE_ARN on the tbd-backups workspace."
  value       = aws_iam_role.tfc_backups_provisioner.arn
}

output "tfc_plan_role_arn" {
  description = "Set as TFC_AWS_PLAN_ROLE_ARN on the tbd-backups workspace. Read-only, and explicitly denied any path to backup content -- speculative plans run on unapproved PRs."
  value       = aws_iam_role.tfc_backups_plan.arn
}
