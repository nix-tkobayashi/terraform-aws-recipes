# GuardDuty for one region. Findings are imported into Security Hub automatically
# (integration is on by default) and notified from the Security Hub home region,
# so this module creates no EventBridge rule of its own.
#
# Every feature in local.optional_features is declared with an explicit status:
# a new detector turns most of them on by default, and undeclared features
# would silently stay enabled (and billed) in regions meant to run foundational
# sources only. Append newer features (e.g. AI_PROTECTION) to the list once
# they are available in your account so they are pinned as well.

locals {
  optional_features = [
    "S3_DATA_EVENTS",
    "EKS_AUDIT_LOGS",
    "EBS_MALWARE_PROTECTION", # Malware Protection for EC2 (S3 Malware Protection is a separate per-bucket plan)
    "RDS_LOGIN_EVENTS",
    "LAMBDA_NETWORK_LOGS",
    "RUNTIME_MONITORING",
  ]
}

resource "aws_guardduty_detector" "this" {
  enable                       = true
  finding_publishing_frequency = var.finding_publishing_frequency
}

resource "aws_guardduty_detector_feature" "this" {
  for_each = toset(local.optional_features)

  detector_id = aws_guardduty_detector.this.id
  name        = each.value
  status      = contains(var.enabled_features, each.value) ? "ENABLED" : "DISABLED"

  dynamic "additional_configuration" {
    for_each = each.value == "RUNTIME_MONITORING" ? var.runtime_monitoring_agents : {}
    content {
      name   = additional_configuration.key
      status = additional_configuration.value
    }
  }
}

# --- Organizations: auto-enable members (delegated administrator only) ---
resource "aws_guardduty_organization_configuration" "this" {
  count = var.manage_organization ? 1 : 0

  detector_id                      = aws_guardduty_detector.this.id
  auto_enable_organization_members = var.auto_enable_organization_members
}

resource "aws_guardduty_organization_configuration_feature" "this" {
  for_each = var.manage_organization ? toset(local.optional_features) : toset([])

  detector_id = aws_guardduty_detector.this.id
  name        = each.value
  auto_enable = contains(var.organization_enabled_features, each.value) ? "ALL" : "NONE"

  dynamic "additional_configuration" {
    for_each = each.value == "RUNTIME_MONITORING" ? var.runtime_monitoring_agents : {}
    content {
      name        = additional_configuration.key
      auto_enable = additional_configuration.value == "ENABLED" ? "ALL" : "NONE"
    }
  }

  depends_on = [aws_guardduty_organization_configuration.this]
}
