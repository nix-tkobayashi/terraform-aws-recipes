variable "resource_types" {
  description = "Scan types to enable for the calling account in this region (EC2, ECR, LAMBDA, LAMBDA_CODE)"
  type        = list(string)
  default     = ["EC2", "ECR", "LAMBDA"]
}

variable "member_account_ids" {
  description = "Existing member accounts to enable now. The organization auto-enable setting applies to accounts that join later only"
  type        = list(string)
  default     = []
}

variable "manage_organization" {
  description = "Set the organization-wide auto-enable defaults. Requires the calling account to be the Inspector delegated administrator"
  type        = bool
  default     = false
}
