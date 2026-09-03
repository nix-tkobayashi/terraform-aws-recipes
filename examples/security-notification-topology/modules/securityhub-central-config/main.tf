# Central configuration, run from the delegated administrator in the home region.
# Requires cross-region aggregation to exist first (the aggregator defines home
# and linked regions). Not available when the management account is the
# delegated administrator.

locals {
  name_prefix = "${var.service_name}-${var.environment}"
}

resource "aws_securityhub_organization_configuration" "this" {
  auto_enable           = false
  auto_enable_standards = "NONE"

  organization_configuration {
    configuration_type = "CENTRAL"
  }
}

resource "aws_securityhub_configuration_policy" "this" {
  name        = "${local.name_prefix}-baseline"
  description = "Security Hub enabled with the listed standards in every linked region"

  configuration_policy {
    service_enabled       = true
    enabled_standard_arns = var.enabled_standards

    security_controls_configuration {
      disabled_control_identifiers = var.disabled_control_ids
    }
  }

  depends_on = [aws_securityhub_organization_configuration.this]
}

resource "aws_securityhub_configuration_policy_association" "this" {
  target_id = var.target_id
  policy_id = aws_securityhub_configuration_policy.this.id
}
