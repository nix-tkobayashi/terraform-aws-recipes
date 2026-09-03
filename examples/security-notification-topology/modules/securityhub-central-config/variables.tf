variable "service_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "enabled_standards" {
  description = "Standards ARNs (without region) enabled for centrally managed accounts"
  type        = list(string)
  default     = ["arn:aws:securityhub:::standards/aws-foundational-security-best-practices/v/1.0.0"]
}

variable "disabled_control_ids" {
  description = "Security control ids disabled in the policy (accepted risks)"
  type        = list(string)
  default     = []
}

variable "target_id" {
  description = "Organization root id (r-xxxx), OU id or account id the policy is associated with"
  type        = string
}
