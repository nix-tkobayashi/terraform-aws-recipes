variable "service_name" {
  description = "Service name used as the first token of resource names"
  type        = string
}

variable "environment" {
  description = "Environment name used as the second token of resource names"
  type        = string
}

variable "dlq_message_retention_seconds" {
  description = "Retention for events that EventBridge could not deliver to the topic"
  type        = number
  default     = 1209600 # 14 days, the maximum
}

variable "kms_master_key_id" {
  description = <<-EOT
    Customer managed KMS key for the topic (Security Hub control SNS.1). The key
    policy must allow events.amazonaws.com (GenerateDataKey*, Decrypt) and the
    subscribers to decrypt; the AWS managed alias/aws/sns key cannot grant that.
    null leaves the topic unencrypted.
  EOT
  type        = string
  default     = null
}
