# Security Hub is enabled per region; findings from linked regions are
# replicated to the home region, where the only notification rules live.
# Repeat "securityhub_<region>" for every region where GuardDuty is enabled,
# and keep var.linked_regions in sync.

module "securityhub_home" {
  source = "../modules/securityhub-region"
}

# Global-resource controls are evaluated in the home region only.
module "securityhub_us_east_1" {
  source            = "../modules/securityhub-region"
  disabled_controls = var.global_resource_controls
  providers         = { aws = aws.us_east_1 }
}

module "securityhub_us_west_2" {
  source            = "../modules/securityhub-region"
  disabled_controls = var.global_resource_controls
  providers         = { aws = aws.us_west_2 }
}

module "securityhub_rules" {
  source = "../modules/securityhub-home"

  service_name   = var.service_name
  environment    = var.environment
  linking_mode   = "SPECIFIED_REGIONS"
  linked_regions = var.linked_regions

  sns_topic_arn = module.topic_home.topic_arn
  dlq_arn       = module.topic_home.dlq_arn
  mark_notified = true # notify once per failure episode; accepted risks are SUPPRESSED in Security Hub, not filtered here

  depends_on = [module.securityhub_home, module.securityhub_us_east_1, module.securityhub_us_west_2]
}
