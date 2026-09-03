output "sns_topic_arns" {
  description = "Topics to subscribe from additional consumers (e.g. an investigation Lambda)"
  value = concat(
    [module.topic_home.topic_arn, module.topic_us_east_1.topic_arn],
    var.enable_health_backup_route ? [module.topic_us_west_2[0].topic_arn] : [],
  )
}

output "finding_aggregator_arn" {
  value = module.securityhub_rules.finding_aggregator_arn
}
