variable "service_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "linking_mode" {
  description = "ALL_REGIONS, ALL_REGIONS_EXCEPT_SPECIFIED or SPECIFIED_REGIONS. Keep the linked set equal to the regions where GuardDuty is enabled"
  type        = string
  default     = "SPECIFIED_REGIONS"
}

variable "linked_regions" {
  description = "Regions linked to this home region (SPECIFIED_REGIONS) or excluded from it (ALL_REGIONS_EXCEPT_SPECIFIED)"
  type        = list(string)
  default     = []
}

variable "sns_topic_arn" {
  description = "SNS topic in this region that receives the notifications"
  type        = string
}

variable "dlq_arn" {
  description = "SQS queue in this region used as dead-letter queue for the EventBridge targets"
  type        = string
}

variable "control_severity_labels" {
  description = "Severity labels notified for control findings and other products"
  type        = list(string)
  default     = ["HIGH", "CRITICAL"]
}

variable "excluded_product_names" {
  description = <<-EOT
    ProductName values excluded from the control rule. Health is notified
    directly by the health-route module and GuardDuty has its own rule. Inspector
    is excluded by default because CVE findings arrive in bulk; remove it here
    to notify HIGH/CRITICAL vulnerabilities as well.
  EOT
  type        = list(string)
  default     = ["Inspector", "Health"]
}

variable "excluded_generator_ids" {
  description = "GeneratorId values excluded from the control rule (accepted risks). Use GeneratorId, not SecurityControlId, so findings without a control id still match"
  type        = list(string)
  default     = []
}

variable "notify_guardduty_all_severities" {
  description = "Notify GuardDuty findings at every severity through a dedicated rule"
  type        = bool
  default     = true
}

variable "mark_notified" {
  description = "Route both rules through a Lambda that publishes to SNS and then sets Workflow.Status = NOTIFIED, so a finding is notified once per failure episode. false publishes to SNS directly"
  type        = bool
  default     = true
}
