# AWS Health has no cross-region aggregation and Security Hub imports only a
# security-related subset, so Health is delivered directly from EventBridge in
# each region that receives events: the regions that host workloads, us-east-1
# for global services (IAM, Route 53, CloudFront, billing) and optionally
# us-west-2, which receives account-specific events from every region as backup.

locals {
  name_prefix = "${var.service_name}-${var.environment}"

  # Both detail-types; dropping "AWS Health Abuse Event" loses abuse notices.
  base_pattern = {
    source      = ["aws.health"]
    detail-type = ["AWS Health Event", "AWS Health Abuse Event"]
  }

  detail_filters = merge(
    var.include_backup_events ? {} : { backupEvent = ["false"] },
    length(var.exclude_event_regions) > 0 ? { eventRegion = [{ anything-but = var.exclude_event_regions }] } : {},
  )

  event_pattern = merge(local.base_pattern, length(local.detail_filters) > 0 ? { detail = local.detail_filters } : {})
}

resource "aws_cloudwatch_event_rule" "health_events" {
  name        = "${local.name_prefix}-health-events"
  description = "AWS Health events (issue / scheduledChange / accountNotification / investigation / abuse)"
  state       = "ENABLED"

  event_pattern = jsonencode(local.event_pattern)
}

resource "aws_cloudwatch_event_target" "health_events" {
  rule      = aws_cloudwatch_event_rule.health_events.name
  target_id = "sns"
  arn       = var.sns_topic_arn

  dead_letter_config {
    arn = var.dlq_arn
  }
}
