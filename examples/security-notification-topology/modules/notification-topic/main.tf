# One SNS topic per region that hosts EventBridge rules. EventBridge can only
# publish to a topic in its own region, so every region with a rule needs one.
# Subscribers (Chatbot, Lambda) may live elsewhere and subscribe cross-region.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.service_name}-${var.environment}"

  # Only rules created by this layout (same prefix) may publish or dead-letter.
  rule_arn_pattern = "arn:aws:events:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:rule/${local.name_prefix}-*"
}

resource "aws_sns_topic" "security_notifications" {
  name              = "${local.name_prefix}-security-notifications"
  kms_master_key_id = var.kms_master_key_id
}

data "aws_iam_policy_document" "topic" {
  statement {
    sid     = "AllowEventBridgePublish"
    effect  = "Allow"
    actions = ["sns:Publish"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    resources = [aws_sns_topic.security_notifications.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.rule_arn_pattern]
    }
  }
}

resource "aws_sns_topic_policy" "security_notifications" {
  arn    = aws_sns_topic.security_notifications.arn
  policy = data.aws_iam_policy_document.topic.json
}

# Dead-letter queue for EventBridge targets. Without it an undeliverable event
# is dropped after the retry policy and only the FailedInvocations metric remains.
resource "aws_sqs_queue" "eventbridge_dlq" {
  name                      = "${local.name_prefix}-security-notifications-dlq"
  message_retention_seconds = var.dlq_message_retention_seconds
}

data "aws_iam_policy_document" "dlq" {
  statement {
    sid     = "AllowEventBridgeSendMessage"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    resources = [aws_sqs_queue.eventbridge_dlq.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.rule_arn_pattern]
    }
  }
}

resource "aws_sqs_queue_policy" "eventbridge_dlq" {
  queue_url = aws_sqs_queue.eventbridge_dlq.id
  policy    = data.aws_iam_policy_document.dlq.json
}
