# The notification path lives in the management account in this layout. SCPs do
# not apply here; restrict IAM access to these resources tightly.

module "topic_home" {
  source       = "../modules/notification-topic"
  service_name = var.service_name
  environment  = var.environment
}

module "topic_us_east_1" {
  source       = "../modules/notification-topic"
  service_name = var.service_name
  environment  = var.environment
  providers    = { aws = aws.us_east_1 }
}

data "aws_iam_policy_document" "chatbot_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["chatbot.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "chatbot_notifications" {
  statement {
    effect = "Allow"
    actions = [
      "cloudwatch:Describe*", "cloudwatch:Get*", "cloudwatch:List*",
      "logs:Get*", "logs:List*", "logs:Describe*", "logs:StartQuery", "logs:StopQuery", "logs:TestMetricFilter", "logs:FilterLogEvents",
      "sns:Get*", "sns:List*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "chatbot" {
  count              = var.slack_channel_id != "" ? 1 : 0
  name               = "${local.name_prefix}-chatbot"
  assume_role_policy = data.aws_iam_policy_document.chatbot_assume_role.json
}

resource "aws_iam_role_policy" "chatbot" {
  count  = var.slack_channel_id != "" ? 1 : 0
  name   = "${local.name_prefix}-chatbot-notifications"
  role   = aws_iam_role.chatbot[0].id
  policy = data.aws_iam_policy_document.chatbot_notifications.json
}

resource "aws_chatbot_slack_channel_configuration" "security" {
  count    = var.slack_channel_id != "" ? 1 : 0
  provider = aws.chatbot

  configuration_name    = "${local.name_prefix}-security-notifications"
  iam_role_arn          = aws_iam_role.chatbot[0].arn
  slack_team_id         = var.slack_team_id
  slack_channel_id      = var.slack_channel_id
  logging_level         = "ERROR"
  guardrail_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
  sns_topic_arns        = [module.topic_home.topic_arn, module.topic_us_east_1.topic_arn]
}
