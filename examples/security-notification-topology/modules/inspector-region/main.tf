# Amazon Inspector for one region. Enable only where scannable resources exist;
# findings flow into Security Hub and are excluded from Slack by default in the
# securityhub-home module (volume), so review them in the console.

data "aws_caller_identity" "current" {}

resource "aws_inspector2_enabler" "this" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = var.resource_types
}

# Existing members are not covered by the organization auto-enable setting.
resource "aws_inspector2_enabler" "members" {
  count = length(var.member_account_ids) > 0 ? 1 : 0

  account_ids    = var.member_account_ids
  resource_types = var.resource_types

  depends_on = [aws_inspector2_organization_configuration.this]
}

resource "aws_inspector2_organization_configuration" "this" {
  count = var.manage_organization ? 1 : 0

  auto_enable {
    ec2         = contains(var.resource_types, "EC2")
    ecr         = contains(var.resource_types, "ECR")
    lambda      = contains(var.resource_types, "LAMBDA")
    lambda_code = contains(var.resource_types, "LAMBDA_CODE")
  }

  depends_on = [aws_inspector2_enabler.this]
}
