locals {
  name_prefix = "${var.service_name}-${var.environment}"

  common_tags = {
    service     = var.service_name
    environment = var.environment
    managed_by  = "terraform"
  }

  # Workload-dependent GuardDuty protections belong only where workloads run.
  guardduty_full_features = ["S3_DATA_EVENTS", "RDS_LOGIN_EVENTS", "EBS_MALWARE_PROTECTION", "LAMBDA_NETWORK_LOGS", "RUNTIME_MONITORING"]
  guardduty_runtime_agents = {
    ECS_FARGATE_AGENT_MANAGEMENT = "ENABLED"
    EC2_AGENT_MANAGEMENT         = "DISABLED"
    EKS_ADDON_MANAGEMENT         = "DISABLED"
  }

  # Foundational data sources (CloudTrail, VPC Flow Logs, DNS) are always on;
  # an empty list sets every optional feature to DISABLED.
  guardduty_basic_features = []
}
