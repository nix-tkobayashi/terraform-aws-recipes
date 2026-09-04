# Organizational view feed (delegated from the management account) arrives in
# each region of this account like the account's own events.
module "health_home" {
  source        = "../../modules/health-route"
  service_name  = var.service_name
  environment   = var.environment
  sns_topic_arn = module.topic_home.topic_arn
  dlq_arn       = module.topic_home.dlq_arn
}

module "health_us_east_1" {
  source        = "../../modules/health-route"
  service_name  = var.service_name
  environment   = var.environment
  sns_topic_arn = module.topic_us_east_1.topic_arn
  dlq_arn       = module.topic_us_east_1.dlq_arn
  providers     = { aws = aws.us_east_1 }
}
