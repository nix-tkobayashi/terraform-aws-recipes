# Health is delivered per region. Home region for regional events, us-east-1
# for global services, optionally us-west-2 for account-specific events from
# every other region (backup delivery; public events are not included).

module "health_home" {
  source        = "../modules/health-route"
  service_name  = var.service_name
  environment   = var.environment
  sns_topic_arn = module.topic_home.topic_arn
  dlq_arn       = module.topic_home.dlq_arn
}

module "health_us_east_1" {
  source        = "../modules/health-route"
  service_name  = var.service_name
  environment   = var.environment
  sns_topic_arn = module.topic_us_east_1.topic_arn
  dlq_arn       = module.topic_us_east_1.dlq_arn
  providers     = { aws = aws.us_east_1 }
  # us-east-1 is the backup for us-west-2; drop those copies when us-west-2 has its own rule
  include_backup_events = !var.enable_health_backup_route
}

module "health_us_west_2" {
  count         = var.enable_health_backup_route ? 1 : 0
  source        = "../modules/health-route"
  service_name  = var.service_name
  environment   = var.environment
  sns_topic_arn = module.topic_us_west_2[0].topic_arn
  dlq_arn       = module.topic_us_west_2[0].dlq_arn
  providers     = { aws = aws.us_west_2 }
  # Backup copies of home and us-east-1 events are already notified by their own
  # rules; keep only the regions that have none.
  exclude_event_regions = [var.home_region, "us-east-1"]
}
