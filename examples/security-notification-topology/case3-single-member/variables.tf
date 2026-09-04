variable "service_name" {
  type    = string
  default = "example"
}

variable "environment" {
  description = "Account-level resources live in one workspace; use a name such as global or security"
  type        = string
  default     = "global"
}

variable "home_region" {
  description = "Security Hub home (aggregation) region. Rules and the primary SNS topic live here"
  type        = string
  default     = "ap-northeast-1"
}

variable "linked_regions" {
  description = "Regions linked to the home region. Must include every region where GuardDuty is enabled"
  type        = list(string)
  default     = ["us-east-1", "us-west-2"]
}

variable "enable_health_backup_route" {
  description = "Add a Health rule in us-west-2 to catch account-specific events from regions that have no rule of their own"
  type        = bool
  default     = false
}

variable "global_resource_controls" {
  description = <<-EOT
    FSBP control ids that evaluate global resources; disabled outside the home
    region so the same account-level finding is not raised once per region.
    Verify against "Controls that you might want to disable" in the Security Hub
    User Guide before applying.
  EOT
  type        = list(string)
  default     = ["Account.1", "IAM.1", "IAM.2", "IAM.3", "IAM.4", "IAM.5", "IAM.6", "IAM.7", "IAM.8", "IAM.21", "KMS.1", "KMS.2"]
}

variable "slack_team_id" {
  description = "Slack workspace id already authorized in the Chatbot console. Empty disables the Chatbot configuration"
  type        = string
  default     = ""
}

variable "slack_channel_id" {
  type    = string
  default = ""
}
