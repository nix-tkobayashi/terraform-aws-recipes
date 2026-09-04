# Optional Lambda that publishes the event to SNS and then marks the findings
# NOTIFIED (see src/mark_notified.py). Replaces the direct SNS targets.

data "archive_file" "mark_notified" {
  count = var.mark_notified ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/src/mark_notified.py"
  output_path = "${path.module}/.build/mark_notified.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "mark_notified" {
  count = var.mark_notified ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [var.sns_topic_arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["securityhub:BatchUpdateFindings"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [var.dlq_arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.mark_notified[0].arn}:*"]
  }
}

resource "aws_cloudwatch_log_group" "mark_notified" {
  count = var.mark_notified ? 1 : 0

  name              = "/aws/lambda/${local.name_prefix}-securityhub-mark-notified"
  retention_in_days = 30
}

resource "aws_iam_role" "mark_notified" {
  count = var.mark_notified ? 1 : 0

  name               = "${local.name_prefix}-securityhub-mark-notified"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "mark_notified" {
  count = var.mark_notified ? 1 : 0

  name   = "${local.name_prefix}-securityhub-mark-notified"
  role   = aws_iam_role.mark_notified[0].id
  policy = data.aws_iam_policy_document.mark_notified[0].json
}

resource "aws_lambda_function" "mark_notified" {
  count = var.mark_notified ? 1 : 0

  function_name    = "${local.name_prefix}-securityhub-mark-notified"
  role             = aws_iam_role.mark_notified[0].arn
  runtime          = "python3.12"
  handler          = "mark_notified.handler"
  filename         = data.archive_file.mark_notified[0].output_path
  source_code_hash = data.archive_file.mark_notified[0].output_base64sha256
  timeout          = 30

  depends_on = [aws_cloudwatch_log_group.mark_notified]

  environment {
    variables = { TOPIC_ARN = var.sns_topic_arn }
  }

  dead_letter_config {
    target_arn = var.dlq_arn
  }
}

resource "aws_lambda_permission" "mark_notified" {
  for_each = var.mark_notified ? merge(
    { control = aws_cloudwatch_event_rule.control_findings.arn },
    var.notify_guardduty_all_severities ? { guardduty = aws_cloudwatch_event_rule.guardduty_findings[0].arn } : {},
  ) : {}

  statement_id  = "AllowEventBridge-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.mark_notified[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = each.value
}

resource "aws_cloudwatch_event_target" "control_mark_notified" {
  count = var.mark_notified ? 1 : 0

  rule      = aws_cloudwatch_event_rule.control_findings.name
  target_id = "notify-and-mark"
  arn       = aws_lambda_function.mark_notified[0].arn

  dead_letter_config {
    arn = var.dlq_arn
  }
}

resource "aws_cloudwatch_event_target" "guardduty_mark_notified" {
  count = var.mark_notified && var.notify_guardduty_all_severities ? 1 : 0

  rule      = aws_cloudwatch_event_rule.guardduty_findings[0].name
  target_id = "notify-and-mark"
  arn       = aws_lambda_function.mark_notified[0].arn

  dead_letter_config {
    arn = var.dlq_arn
  }
}
