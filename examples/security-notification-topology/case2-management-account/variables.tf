variable "service_name" {
  type    = string
  default = "example"
}

variable "environment" {
  type    = string
  default = "security"
}

variable "home_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "linked_regions" {
  description = "Regions linked to the home region; must equal the regions where GuardDuty is enabled"
  type        = list(string)
  default     = ["us-east-1"]
}

variable "global_resource_controls" {
  type    = list(string)
  default = ["Account.1", "IAM.1", "IAM.2", "IAM.3", "IAM.4", "IAM.5", "IAM.6", "IAM.7", "IAM.8", "IAM.21", "KMS.1", "KMS.2"]
}

variable "member_account_ids" {
  description = "Existing member accounts to enable Inspector in (auto-enable covers new accounts only)"
  type        = list(string)
  default     = []
}

variable "slack_team_id" {
  type    = string
  default = ""
}

variable "slack_channel_id" {
  type    = string
  default = ""
}
