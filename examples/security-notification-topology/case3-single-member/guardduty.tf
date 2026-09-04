# Detectors in every linked region (unauthorized use is detected wherever it
# happens); workload-dependent protections only where workloads run.

module "guardduty_home" {
  source                    = "../modules/guardduty-region"
  enabled_features          = local.guardduty_full_features
  runtime_monitoring_agents = local.guardduty_runtime_agents
}

module "guardduty_us_east_1" {
  source           = "../modules/guardduty-region"
  enabled_features = local.guardduty_basic_features
  providers        = { aws = aws.us_east_1 }
}

module "guardduty_us_west_2" {
  source           = "../modules/guardduty-region"
  enabled_features = local.guardduty_basic_features
  providers        = { aws = aws.us_west_2 }
}
