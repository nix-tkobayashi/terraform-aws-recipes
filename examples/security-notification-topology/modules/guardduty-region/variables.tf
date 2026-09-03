variable "finding_publishing_frequency" {
  description = "How often updates to existing findings are exported (FIFTEEN_MINUTES, ONE_HOUR, SIX_HOURS)"
  type        = string
  default     = "SIX_HOURS"
}

variable "enabled_features" {
  description = <<-EOT
    Optional detector features to ENABLE in this region. Every feature in
    local.optional_features that is not listed is set to DISABLED explicitly,
    because a new detector enables most optional features by default.
    Values: S3_DATA_EVENTS, EKS_AUDIT_LOGS, EBS_MALWARE_PROTECTION,
    RDS_LOGIN_EVENTS, LAMBDA_NETWORK_LOGS, RUNTIME_MONITORING.
  EOT
  type        = list(string)
  default     = []
}

variable "runtime_monitoring_agents" {
  description = "Agent management for RUNTIME_MONITORING. All three keys are always declared (AWS returns them all); ENABLED or DISABLED"
  type        = map(string)
  default = {
    ECS_FARGATE_AGENT_MANAGEMENT = "DISABLED"
    EC2_AGENT_MANAGEMENT         = "DISABLED"
    EKS_ADDON_MANAGEMENT         = "DISABLED"
  }
}

# --- Organizations (delegated administrator roots only) ---
variable "manage_organization" {
  description = "Create the organization configuration for member accounts. Requires the calling account to be the GuardDuty delegated administrator in this region"
  type        = bool
  default     = false
}

variable "auto_enable_organization_members" {
  description = "ALL, NEW or NONE"
  type        = string
  default     = "ALL"
}

variable "organization_enabled_features" {
  description = "Feature names auto-enabled (ALL) for member accounts; the rest of local.optional_features are set to NONE"
  type        = list(string)
  default     = []
}
