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
  name         = "platform-alerts"
  display_name = "FJ Consulting platform alerts" # sender name on email subscriptions
}

locals {
  account_id = "884686184019"
}

# Budget alerts reach the owner through platform-alerts. The email subscription stays pending
# until the owner clicks the confirmation link AWS sends.
resource "aws_sns_topic_subscription" "owner_email" {
  topic_arn = aws_sns_topic.platform_alerts.arn
  protocol  = "email"
  endpoint  = "flamarion@fjconsulting.io"
}

data "aws_iam_policy_document" "platform_alerts" {
  statement {
    sid       = "BudgetsPublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.platform_alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "platform_alerts" {
  arn    = aws_sns_topic.platform_alerts.arn
  policy = data.aws_iam_policy_document.platform_alerts.json
}

# Gross spend (credits and refunds excluded), so the alerts fire while credits still cover the bill
# (INFRA-11). Actual 50% = $25, actual 100% = $50, plus a forecast warning at $50.
resource "aws_budgets_budget" "monthly" {
  name         = "platform-monthly"
  budget_type  = "COST"
  limit_amount = "50"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit = false
    include_refund = false
  }

  dynamic "notification" {
    for_each = {
      actual_25   = { type = "ACTUAL", threshold = 50 }
      actual_50   = { type = "ACTUAL", threshold = 100 }
      forecast_50 = { type = "FORECASTED", threshold = 100 }
    }
    content {
      notification_type         = notification.value.type
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value.threshold
      threshold_type            = "PERCENTAGE"
      subscriber_sns_topic_arns = [aws_sns_topic.platform_alerts.arn]
    }
  }

  depends_on = [aws_sns_topic_policy.platform_alerts]
}

# Management-events trail, all regions: the first copy of management events is free, and a
# compromised key is most often used in a region nobody watches. Event history covers 90 days;
# the bucket keeps a year.
resource "aws_s3_bucket" "trail" {
  bucket = "fjc-platform-cloudtrail-${local.account_id}"
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket                  = aws_s3_bucket.trail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    id     = "expire-after-a-year"
    status = "Enabled"
    filter {}
    expiration {
      days = 365
    }
  }
}

data "aws_iam_policy_document" "trail_bucket" {
  statement {
    sid       = "CloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:eu-central-1:${local.account_id}:trail/platform-management"]
    }
  }
  statement {
    sid       = "CloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail.arn}/AWSLogs/${local.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:eu-central-1:${local.account_id}:trail/platform-management"]
    }
  }
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.trail.arn, "${aws_s3_bucket.trail.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = data.aws_iam_policy_document.trail_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.trail]
}

resource "aws_cloudtrail" "platform" {
  name                          = "platform-management"
  s3_bucket_name                = aws_s3_bucket.trail.id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.trail]
}
