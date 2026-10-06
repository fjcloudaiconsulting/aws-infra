variable "aws_region" {
  description = "AWS region for the S3 bucket and the home of the default provider. CloudFront is global; ACM for CloudFront is pinned to us-east-1 in providers.tf regardless of this value."
  type        = string
  default     = "eu-central-1"
}

variable "domain" {
  description = "Apex domain to serve. Both apex and www.<apex> are added as CloudFront aliases and ACM SANs."
  type        = string
  default     = "thebetterdecision.com"
}

variable "github_repo" {
  description = "GitHub repo (owner/name) allowed to assume the GitHub Actions deploy role via OIDC."
  type        = string
  default     = "fjcloudaiconsulting/tbd"
}

variable "github_main_branch" {
  description = "Branch on github_repo whose workflow runs are allowed to assume the deploy role. The OIDC trust policy uses StringEquals on the sub claim, so only this exact branch ref can deploy. PR contexts are rejected at the trust level (not just by workflow-level guards), since PR authors could otherwise edit the workflow to bypass guards."
  type        = string
  default     = "main"
}

variable "noncurrent_version_expiration_days" {
  description = "Days after which noncurrent S3 object versions expire. Versioning stays on for rollback; this caps storage growth."
  type        = number
  default     = 90
}

variable "orphaned_static_expiration_days" {
  description = "Days after which current _next/static/ objects expire. Hashed chunks orphaned by a Next.js rename never become noncurrent versions (the key changes entirely), so the noncurrent-version rule never prunes them. The apex deploy re-uploads every in-use chunk, refreshing its mtime, so a window this wide only reaps chunks no recent build referenced. Matches noncurrent_version_expiration_days for a generous safety margin."
  type        = number
  default     = 90
}

variable "access_log_expiration_days" {
  description = "Days after which CloudFront access log objects expire from the dedicated logs bucket. Standard CloudFront logs are operational telemetry (not records of intent), so a 90-day window is enough for incident forensics and traffic analysis while capping storage growth."
  type        = number
  default     = 90

  validation {
    condition     = var.access_log_expiration_days >= 1
    error_message = "access_log_expiration_days must be at least 1."
  }
}
