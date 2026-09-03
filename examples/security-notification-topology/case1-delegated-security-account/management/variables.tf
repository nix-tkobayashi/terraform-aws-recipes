variable "home_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "management_role_arn" {
  description = "Role in the management account used by Terraform"
  type        = string
}

variable "security_account_id" {
  description = "The security tooling account that becomes delegated administrator for every service"
  type        = string
}
