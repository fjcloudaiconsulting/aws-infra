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

# Route 53 health-check metrics exist only in us-east-1, so the uptime alarm and the topic it
# notifies live there (INFRA-26).
provider "aws" {
  alias               = "use1"
  region              = "us-east-1"
  allowed_account_ids = ["884686184019"]

  default_tags {
    tags = {
      managed_by = "terraform"
      stack      = "platform"
    }
  }
}

locals {
  account_id  = "884686184019"
  owner_email = "flamarion@fjconsulting.io"
}

# Alarm and budget notifications land here (INFRA-11/26). Also the first real resource, so the
# first merge exercises the apply role: a no-change plan never reaches apply.
resource "aws_sns_topic" "platform_alerts" {
  name         = "platform-alerts"
  display_name = "FJ Consulting platform alerts" # sender name on email subscriptions
}

# Budget alerts reach the owner through platform-alerts. The email subscription stays pending
# until the owner clicks the confirmation link AWS sends.
resource "aws_sns_topic_subscription" "owner_email" {
  topic_arn = aws_sns_topic.platform_alerts.arn
  protocol  = "email"
  endpoint  = local.owner_email
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
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:budgets::${local.account_id}:*"]
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
# The trail's log bucket stays when the stack is destroyed (INFRA-176: buckets and roles stay); its lifecycle rule
# keeps expiring logs after a year, and its policy only lets CloudTrail write, which stops with the trail.
locals {
  trail_bucket = "fjc-platform-cloudtrail-${local.account_id}"
}

removed {
  from = aws_s3_bucket.trail
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_public_access_block.trail
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_lifecycle_configuration.trail
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_policy.trail
  lifecycle {
    destroy = false
  }
}

resource "aws_cloudtrail" "platform" {
  name                          = "platform-management"
  s3_bucket_name                = local.trail_bucket
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
}

# The single k3s node (INFRA-21/22). user_data (the launch script) is ignored after the first boot. prevent_destroy
# guarded the in-cluster databases; it went once they moved to Hetzner (INFRA-175), so INFRA-176 can destroy the stack.
variable "k3s_version" {
  description = "k3s release installed at first boot. Upgrading a running node is a separate, manual step."
  type        = string
  default     = "v1.36.5+k3s1"
}

resource "aws_lightsail_instance" "node" {
  name              = "platform-node"
  availability_zone = "eu-central-1a"
  blueprint_id      = "ubuntu_24_04"
  bundle_id         = "medium_3_0" # 2 vCPU, 4 GB, 80 GB, IPv4 included. The IPv6-only bundle cannot reach GitHub or GHCR.
  ip_address_type   = "ipv4"       # Cloudflare reaches the static IPv4; IPv6 is not used.
  user_data         = templatefile("${path.module}/node-init.sh.tftpl", { k3s_version = var.k3s_version })

  add_on {
    type          = "AutoSnapshot"
    snapshot_time = "03:00" # UTC, after the 02:00 database dump
    status        = "Enabled"
  }

  lifecycle {
    ignore_changes = [user_data]
  }
}

resource "aws_lightsail_static_ip" "node" {
  name = "platform-node-ip" # Lightsail names are unique across resource types, so not the instance's name
}

resource "aws_lightsail_static_ip_attachment" "node" {
  static_ip_name = aws_lightsail_static_ip.node.name
  instance_name  = aws_lightsail_instance.node.name
}

# Replaces the instance's default rules (22 and 80 open to all). 443 only from Cloudflare,
# 22 only through the Lightsail console (and any owner CIDR), 6443 and 80 closed.
# ⚠ Never let Terraform destroy this resource. port_info is ForceNew, and the provider's
# delete calls CloseInstancePublicPorts per rule: on 2026-10-01 Lightsail failed every close of
# the 443 rule with "ServiceException: ... trouble with your network settings", and the apply
# hung until cancelled. PutInstancePublicPorts (create) replaces the whole rule set and works.
# So a port_info change goes in as a new resource address plus a `removed` block with
# destroy = false for the old one: the new Put overwrites the old rules, nothing is closed.
removed {
  from = aws_lightsail_instance_public_ports.node

  lifecycle {
    destroy = false
  }
}

# The firewall (443 from Cloudflare, 22 for Lightsail connect) is released, not destroyed (INFRA-176): its delete calls
# CloseInstancePublicPorts, the call that hung on 2026-10-01 (above). The rules go with the instance.
removed {
  from = aws_lightsail_instance_public_ports.firewall
  lifecycle {
    destroy = false
  }
}

# Lightsail metrics never reach CloudWatch and the AWS provider has no Lightsail alarm resource,
# so the node's alarms (INFRA-26) live in a CloudFormation stack. Lightsail alarms notify only a
# Lightsail contact method; creating it emails a verification link, and nothing is sent until the
# owner clicks it. One email contact method per region: the create fails if one already exists.
resource "aws_cloudformation_stack" "node_alarms" {
  name = "platform-node-alarms"
  template_body = jsonencode({
    Resources = {
      OwnerEmail = {
        Type       = "AWS::Lightsail::ContactMethod"
        Properties = { Protocol = "Email", ContactEndpoint = local.owner_email }
      }
      # Credits under 20% for 10 minutes: sustained load is about to be throttled to baseline.
      BurstCapacity = {
        Type      = "AWS::Lightsail::Alarm"
        DependsOn = "OwnerEmail"
        Properties = {
          AlarmName             = "platform-node-burst-capacity"
          MonitoredResourceName = aws_lightsail_instance.node.name
          MetricName            = "BurstCapacityPercentage"
          ComparisonOperator    = "LessThanOrEqualToThreshold"
          Threshold             = 20
          EvaluationPeriods     = 2
          DatapointsToAlarm     = 2
          TreatMissingData      = "notBreaching" # a silent node is the status check's job
          ContactProtocols      = ["Email"]
          NotificationTriggers  = ["ALARM", "OK"]
        }
      }
      # Missing data counts as failed, so a stopped or hung node alarms too.
      StatusCheck = {
        Type      = "AWS::Lightsail::Alarm"
        DependsOn = "OwnerEmail"
        Properties = {
          AlarmName             = "platform-node-status-check"
          MonitoredResourceName = aws_lightsail_instance.node.name
          MetricName            = "StatusCheckFailed"
          ComparisonOperator    = "GreaterThanOrEqualToThreshold"
          Threshold             = 1
          EvaluationPeriods     = 2
          DatapointsToAlarm     = 2
          TreatMissingData      = "breaching"
          ContactProtocols      = ["Email"]
          NotificationTriggers  = ["ALARM", "OK"]
        }
      }
    }
  })
}

# External uptime check (INFRA-26): Route 53 checkers in several regions fetch TBD's
# /health/dependencies through Cloudflare (since the INFRA-48 cutover; Traefik's /ping before), so a
# dead node, broken DNS, proxy, origin certificate, app, MySQL or Valkey all alarm (503 when MySQL or
# Valkey is unusable). Updating fqdn and path keeps the check id, so the alarm below stays wired.
# HTTPS (not HTTP): Cloudflare would answer plain HTTP with a 301 itself, and 3xx counts as healthy.
# No string matching: each optional feature costs $2/month on a non-AWS endpoint, and every
# Cloudflare failure (52x, a 403 challenge) is already a non-2xx/3xx status.
# If Bot Fight Mode, a higher security level or WAF challenges are ever enabled, skip this path:
# Route 53 checkers would get a 403 and page as an outage.
resource "aws_route53_health_check" "ping" {
  type              = "HTTPS"
  fqdn              = "app.thebetterdecision.com"
  port              = 443
  resource_path     = "/health/dependencies"
  enable_sni        = true # Cloudflare needs SNI to pick the certificate
  request_interval  = 30
  failure_threshold = 3

  tags = { Name = "platform-ping" }
}

resource "aws_sns_topic" "platform_alerts_use1" {
  provider     = aws.use1
  name         = "platform-alerts-use1"
  display_name = "FJ Consulting platform alerts"
}

# A second confirmation email for the owner: this subscription also stays pending until clicked.
resource "aws_sns_topic_subscription" "owner_email_use1" {
  provider  = aws.use1
  topic_arn = aws_sns_topic.platform_alerts_use1.arn
  protocol  = "email"
  endpoint  = local.owner_email
}

data "aws_iam_policy_document" "platform_alerts_use1" {
  statement {
    sid       = "CloudWatchAlarmsPublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.platform_alerts_use1.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudwatch:us-east-1:${local.account_id}:alarm:platform-*"]
    }
  }
}

resource "aws_sns_topic_policy" "platform_alerts_use1" {
  provider = aws.use1
  arn      = aws_sns_topic.platform_alerts_use1.arn
  policy   = data.aws_iam_policy_document.platform_alerts_use1.json
}

# Unhealthy for two straight minutes (the checkers themselves need about 90 s of failures first).
# No data counts as down, so a deleted or stuck check alarms too.
resource "aws_cloudwatch_metric_alarm" "ping" {
  provider            = aws.use1
  alarm_name          = "platform-ping-unhealthy"
  alarm_description   = "app.thebetterdecision.com/health/dependencies failed the Route 53 health check (INFRA-26, INFRA-48)"
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  dimensions          = { HealthCheckId = aws_route53_health_check.ping.id }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.platform_alerts_use1.arn]
  ok_actions          = [aws_sns_topic.platform_alerts_use1.arn]

  depends_on = [aws_sns_topic_policy.platform_alerts_use1]
}

output "node_static_ip" {
  description = "Public IPv4 of the k3s node; Cloudflare proxied records point here."
  value       = aws_lightsail_static_ip.node.ip_address
}
