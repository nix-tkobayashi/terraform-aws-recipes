# Organizational view is enabled in the management account (console: any support
# plan; CLI/API: Business or higher). There is no Terraform resource for it, so
# it is a manual prerequisite. Once enabled, these rules receive one feed for
# every account in the organization.

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
}
