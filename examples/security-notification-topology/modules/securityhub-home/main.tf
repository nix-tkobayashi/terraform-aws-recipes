# Home (aggregation) region: cross-region aggregation plus the EventBridge rules.
# "Security Hub Findings - Imported" fires for every import and update, so the
# rules filter on Workflow.Status = NEW and RecordState = ACTIVE.
#
# Delivery has two modes:
#   mark_notified = false : rule -> SNS topic directly (re-notified on each update)
#   mark_notified = true  : rule -> Lambda, which publishes to SNS and then sets
#                           Workflow.Status = NOTIFIED (once per failure episode).
#                           The Lambda is the only target, so the status changes
#                           only after SNS accepted the message (see notified.tf).

locals {
  name_prefix = "${var.service_name}-${var.environment}"
}

resource "aws_securityhub_finding_aggregator" "this" {
  linking_mode      = var.linking_mode
  specified_regions = var.linking_mode == "ALL_REGIONS" ? null : var.linked_regions
}

# --- Control findings and other integrated products (severity-filtered) ---
resource "aws_cloudwatch_event_rule" "control_findings" {
  name        = "${local.name_prefix}-securityhub-findings"
  description = "Security Hub findings (${join("/", var.control_severity_labels)}, Workflow NEW), GuardDuty excluded"
  state       = "ENABLED"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]
    detail = {
      findings = merge(
        {
          ProductName = [{ anything-but = concat(var.excluded_product_names, ["GuardDuty"]) }]
          Severity    = { Label = var.control_severity_labels }
          Workflow    = { Status = ["NEW"] }
          RecordState = ["ACTIVE"]
        },
        length(var.excluded_generator_ids) > 0 ? { GeneratorId = [{ anything-but = var.excluded_generator_ids }] } : {}
      )
    }
  })
}

resource "aws_cloudwatch_event_target" "control_findings" {
  count = var.mark_notified ? 0 : 1

  rule      = aws_cloudwatch_event_rule.control_findings.name
  target_id = "sns"
  arn       = var.sns_topic_arn

  dead_letter_config {
    arn = var.dlq_arn
  }
}

# --- GuardDuty findings via Security Hub (all severities) ---
# GuardDuty imports every finding into Security Hub, so no native GuardDuty
# rule is needed; keeping both would notify each finding twice.
resource "aws_cloudwatch_event_rule" "guardduty_findings" {
  count = var.notify_guardduty_all_severities ? 1 : 0

  name        = "${local.name_prefix}-securityhub-guardduty-findings"
  description = "GuardDuty findings via Security Hub (all severities, Workflow NEW)"
  state       = "ENABLED"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        ProductName = ["GuardDuty"]
        Workflow    = { Status = ["NEW"] }
        RecordState = ["ACTIVE"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_findings" {
  count = var.notify_guardduty_all_severities && !var.mark_notified ? 1 : 0

  rule      = aws_cloudwatch_event_rule.guardduty_findings[0].name
  target_id = "sns"
  arn       = var.sns_topic_arn

  dead_letter_config {
    arn = var.dlq_arn
  }
}
