# Auth: TFC dynamic credentials (TFC_AWS_PROVIDER_AUTH, TFC_AWS_PLAN_ROLE_ARN,
# TFC_AWS_APPLY_ROLE_ARN on the workspace). Roles: aws/bootstrap/tfc-platform-*.json.
provider "aws" {
  region              = "eu-central-1"
  allowed_account_ids = ["884686184019"]

  default_tags {
    tags = {
      managed_by = "terraform"
      stack      = "platform"
    }
  }
}

# Alarm and budget notifications land here (INFRA-11/26). Also the first real resource, so the
# first merge exercises the apply role: a no-change plan never reaches apply.
resource "aws_sns_topic" "platform_alerts" {
  name = "platform-alerts"
}
