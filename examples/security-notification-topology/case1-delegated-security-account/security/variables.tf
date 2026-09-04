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
  description = "Regions linked to the home region and covered by the configuration policy; must equal the regions where GuardDuty is enabled"
  type        = list(string)
  default     = ["us-east-1"]
}

variable "security_role_arn" {
  description = "Role in the security tooling account used by Terraform"
  type        = string
}

variable "organization_root_id" {
  description = "Organizations root id (r-xxxx) or an OU id the configuration policy is associated with"
  type        = string
}

variable "disabled_control_ids" {
  description = "Controls disabled organization-wide in the configuration policy (accepted risks). Global-resource controls are disabled automatically outside the home region by central configuration"
  type        = list(string)
  default     = []
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
