variable "service_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "sns_topic_arn" {
  description = "SNS topic in this region"
  type        = string
}

variable "dlq_arn" {
  description = "SQS dead-letter queue in this region"
  type        = string
}

variable "include_backup_events" {
  description = <<-EOT
    Keep events that AWS Health re-delivers to this region as a backup for another
    region (detail.backupEvent = true). us-west-2 is the backup for every other
    region and us-east-1 is the backup for us-west-2. Set false when you also have
    rules in the primary regions, to avoid double notifications.
  EOT
  type        = bool
  default     = true
}

variable "exclude_event_regions" {
  description = <<-EOT
    Impacted regions (detail.eventRegion) to drop from this rule because they
    have a rule of their own. Use on the us-west-2 backup rule to avoid double
    notifications for the home region and us-east-1.
  EOT
  type        = list(string)
  default     = []
}
