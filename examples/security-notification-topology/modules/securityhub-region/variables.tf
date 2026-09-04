variable "standards" {
  description = "Standards to subscribe in this region, as the path part of a regional standards ARN (standards/...). Region-less rulesets such as CIS v1.2.0 are not supported by this module"
  type        = list(string)
  default     = ["standards/aws-foundational-security-best-practices/v/1.0.0"]

  validation {
    condition     = length(var.standards) > 0 && alltrue([for s in var.standards : startswith(s, "standards/")])
    error_message = "Each entry must start with \"standards/\"; rulesets (ruleset/...) are not supported."
  }
}

variable "enable_default_standards" {
  description = "Let Security Hub subscribe its default standards when the account is enabled. Keep false and list standards explicitly"
  type        = bool
  default     = false
}

variable "disabled_controls" {
  description = <<-EOT
    Control ids (e.g. IAM.6) to disable in this region for the first standard in
    var.standards. Use it outside the home region for controls that evaluate
    global resources, so the same account-level finding is not raised once per
    region. See "Controls that you might want to disable" in the Security Hub
    User Guide for the current list.
  EOT
  type        = list(string)
  default     = []
}
