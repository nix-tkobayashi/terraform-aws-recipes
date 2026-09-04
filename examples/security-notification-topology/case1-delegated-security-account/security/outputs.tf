output "sns_topic_arns" {
  value = [module.topic_home.topic_arn, module.topic_us_east_1.topic_arn]
}
