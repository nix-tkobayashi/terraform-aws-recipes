# Delegated administrator: own detectors plus organization auto-enable per region.
module "guardduty_home" {
  source                        = "../../modules/guardduty-region"
  enabled_features              = local.guardduty_full_features
  runtime_monitoring_agents     = local.guardduty_runtime_agents
  manage_organization           = true
  organization_enabled_features = ["S3_DATA_EVENTS", "RDS_LOGIN_EVENTS", "EBS_MALWARE_PROTECTION", "RUNTIME_MONITORING"]
}

module "guardduty_us_east_1" {
  source                        = "../../modules/guardduty-region"
  enabled_features              = []
  manage_organization           = true
  organization_enabled_features = []
  providers                     = { aws = aws.us_east_1 }
}
