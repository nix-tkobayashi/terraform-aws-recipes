output "topic_arn" {
  description = "SNS topic ARN for EventBridge targets and subscribers"
  value       = aws_sns_topic.security_notifications.arn
}

output "dlq_arn" {
  description = "SQS queue ARN to use as dead_letter_config on EventBridge targets in this region"
  value       = aws_sqs_queue.eventbridge_dlq.arn
}
