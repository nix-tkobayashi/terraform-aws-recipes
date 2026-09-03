# Enables Security Hub CSPM in one region for the calling account and
# subscribes the listed standards. Findings from integrated services
# (GuardDuty, Inspector, Config, Health) are imported automatically.

data "aws_region" "current" {}

resource "aws_securityhub_account" "this" {
  enable_default_standards = var.enable_default_standards
}

resource "aws_securityhub_standards_subscription" "this" {
  for_each = toset(var.standards)

  standards_arn = "arn:aws:securityhub:${data.aws_region.current.region}::${each.value}"

  depends_on = [aws_securityhub_account.this]
}

data "aws_caller_identity" "current" {}

resource "aws_securityhub_standards_control" "disabled" {
  for_each = toset(var.disabled_controls)

  standards_control_arn = "arn:aws:securityhub:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:control/${trimprefix(var.standards[0], "standards/")}/${each.value}"
  control_status        = "DISABLED"
  disabled_reason       = "Global resource; evaluated in the home region only"

  depends_on = [aws_securityhub_standards_subscription.this]
}
