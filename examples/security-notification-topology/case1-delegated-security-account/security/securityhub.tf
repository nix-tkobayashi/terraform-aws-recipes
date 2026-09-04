# Security Hub in the delegated administrator's own regions, the aggregator
# (home + linked regions) and central configuration. Central configuration
# disables global-resource controls outside the home region automatically.

module "securityhub_home" {
  source = "../../modules/securityhub-region"
}

module "securityhub_us_east_1" {
  source    = "../../modules/securityhub-region"
  providers = { aws = aws.us_east_1 }
}

module "securityhub_rules" {
  source = "../../modules/securityhub-home"

  service_name   = var.service_name
  environment    = var.environment
  linking_mode   = "SPECIFIED_REGIONS"
  linked_regions = var.linked_regions
  sns_topic_arn  = module.topic_home.topic_arn
  dlq_arn        = module.topic_home.dlq_arn

  depends_on = [module.securityhub_home, module.securityhub_us_east_1]
}

module "securityhub_central_config" {
  source = "../../modules/securityhub-central-config"

  service_name         = var.service_name
  environment          = var.environment
  target_id            = var.organization_root_id
  disabled_control_ids = var.disabled_control_ids

  depends_on = [module.securityhub_rules] # aggregator (home / linked regions) must exist first
}
