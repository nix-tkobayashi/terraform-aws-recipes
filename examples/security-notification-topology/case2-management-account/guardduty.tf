# The management account designates itself as GuardDuty delegated administrator
# (documented by AWS as not recommended) and auto-enables members per region.

resource "aws_guardduty_organization_admin_account" "home" {
  admin_account_id = data.aws_caller_identity.current.account_id
}

resource "aws_guardduty_organization_admin_account" "us_east_1" {
  provider         = aws.us_east_1
  admin_account_id = data.aws_caller_identity.current.account_id
}

module "guardduty_home" {
  source                        = "../modules/guardduty-region"
  enabled_features              = local.guardduty_full_features
  runtime_monitoring_agents     = local.guardduty_runtime_agents
  manage_organization           = true
  organization_enabled_features = ["S3_DATA_EVENTS", "RDS_LOGIN_EVENTS", "EBS_MALWARE_PROTECTION"]
  depends_on                    = [aws_guardduty_organization_admin_account.home]
}

module "guardduty_us_east_1" {
  source                        = "../modules/guardduty-region"
  enabled_features              = []
  manage_organization           = true
  organization_enabled_features = []
  providers                     = { aws = aws.us_east_1 }
  depends_on                    = [aws_guardduty_organization_admin_account.us_east_1]
}
