# SecurityHub Finding Aggregator — Terraform Construction Prompt

[日本語版](securityhub-finding-aggregator.ja.md)

## Overview

Build a notification pipeline that uses SecurityHub cross-region finding aggregation to deliver GuardDuty findings (MEDIUM severity or higher) to Slack via AWS Chatbot. This is an **alternative to the per-region EventBridge forwarding approach** described in the notification section of [GuardDuty Multi-Region Management](guardduty-multiregion-setup.md).

By leveraging SecurityHub's built-in cross-region replication, all per-region notification resources (EventBridge forwarding rules, custom Event Bus, forwarding IAM Role) are eliminated.

### Why This Approach?

| Aspect | EventBridge Forwarding | SecurityHub Aggregator |
|---|---|---|
| Per-region notification resources | 2 (Rule + Target) | **0** |
| Total notification resources | ~45 | **~10** |
| New region added | Manual (add Rule + Target) | **Automatic** |
| Custom Event Bus required | Yes | **No** |
| Cross-region IAM Role | Yes | **No** |
| SecurityHub dependency | No | Yes (often already enabled) |

### Terminology

| Term | Meaning |
|---|---|
| **aggregation region** | The region where SecurityHub aggregates findings from all linked regions. EventBridge rules and SNS notifications are configured only in this region. |
| **linked region** | Any region whose findings are replicated to the aggregation region via the Finding Aggregator. |
| **ASFF** | AWS Security Finding Format — the standardized finding format used by SecurityHub. GuardDuty findings are automatically converted to ASFF when imported into SecurityHub. |

> **Scope**: This recipe covers only the notification pipeline. GuardDuty core resources (Detectors, members, features, Organization configuration) must be set up separately using [GuardDuty Multi-Region Management](guardduty-multiregion-setup.md) — use only the core section, skip the notification section.

---

## Architecture

```
[All Regions]
  GuardDuty Detector
      ↓ (auto-import)
  SecurityHub ──(Finding Aggregator replicates)──→ [Aggregation Region]
                                                     SecurityHub
                                                         ↓
                                                   EventBridge Rule (MEDIUM+)
                                                         ↓
                                                     SNS Topic
                                                         ↓
                                                    AWS Chatbot
                                                         ↓
                                                       Slack
```

### Comparison with EventBridge Forwarding

```
# EventBridge forwarding (per-region resources required):
[Region A] GuardDuty → EventBridge Rule → ─┐
[Region B] GuardDuty → EventBridge Rule → ─┼→ Custom EventBus → EventBridge Rule → SNS → Slack
[Region C] GuardDuty → EventBridge Rule → ─┘   ↑ IAM Role
                                                ↑ Bus Policy
# Total per non-aggregation region: 2 resources (Rule + Target)
# Total aggregation region: 10 resources (Bus, Policy, 2 Rules, 2 Targets, IAM Role, Role Policy, SNS, SNS Policy)

# SecurityHub aggregator (no per-region resources):
[Region A] GuardDuty → SecurityHub ──┐
[Region B] GuardDuty → SecurityHub ──┼─(automatic)─→ SecurityHub → EventBridge Rule → SNS → Slack
[Region C] GuardDuty → SecurityHub ──┘
# Total: 1 Aggregator + 1 Rule + 1 Target + 1 SNS + 1 SNS Policy = 5 notification resources
```

---

## Prerequisites

| Item | Description |
|---|---|
| **GuardDuty** | Detectors enabled in all target regions (see [GuardDuty Multi-Region Management](guardduty-multiregion-setup.md)) |
| **SecurityHub** | Enabled in all target regions and the aggregation region. Often pre-configured by AWS Control Tower. |
| **Aggregation region** | Region where notifications are centralized (e.g., `ap-northeast-1`) |
| **Slack workspace ID** | Slack workspace ID for AWS Chatbot integration |
| **Slack channel ID** | Slack channel ID for GuardDuty Finding notifications |
| **Terraform backend** | S3 bucket name, key, and region |

### Preparation

- Configure the Slack workspace integration in the AWS Chatbot console beforehand (Terraform cannot manage the workspace connection itself)
- If SecurityHub is not yet enabled in all target regions, add `aws_securityhub_account` to each region's configuration or enable it via AWS Organizations

### Enabling SecurityHub per Region (if not already enabled)

If SecurityHub is not managed by Control Tower, add the following to the [guardduty-region module](guardduty-multiregion-setup.md):

```hcl
resource "aws_securityhub_account" "this" {}
```

For Organizations-wide auto-enablement (in the aggregation region only):

```hcl
resource "aws_securityhub_organization_admin_account" "this" {
  admin_account_id = var.delegated_admin_account_id
}

resource "aws_securityhub_organization_configuration" "this" {
  auto_enable           = true
  auto_enable_standards = "DEFAULT"
  depends_on            = [aws_securityhub_organization_admin_account.this]
}
```

---

## Directory Structure

```
terraform/
├── env/management/
│   ├── backend.tf                               # Provider (aggregation region)
│   ├── locals.tf                                # Project / account IDs / Slack config
│   ├── guardduty.tf                             # GuardDuty core module calls (existing recipe)
│   ├── guardduty_notification.tf                # Notification module call
│   └── chatbot.tf                               # AWS Chatbot Slack integration
│
└── modules/management/guardduty-notification/    # SecurityHub aggregator + EventBridge + SNS
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    └── versions.tf
```

---

## Build Steps

### Step 1: modules/management/guardduty-notification/ — Notification Module

#### variables.tf

```hcl
variable "project" {
  description = "Project name for resource naming"
  type        = string
}

variable "severity_labels" {
  description = "SecurityHub severity labels to notify on"
  type        = list(string)
  default     = ["MEDIUM", "HIGH", "CRITICAL"]
}
```

#### main.tf

```hcl
# =============================================================================
# SecurityHub Finding Aggregator
# =============================================================================

resource "aws_securityhub_finding_aggregator" "this" {
  linking_mode = "ALL_REGIONS"
}

# =============================================================================
# EventBridge — GuardDuty findings via SecurityHub
# =============================================================================

resource "aws_cloudwatch_event_rule" "guardduty_findings" {
  name        = "${var.project}-guardduty-findings"
  description = "Route GuardDuty findings (${join("/", var.severity_labels)}) to SNS via SecurityHub aggregation"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        ProductName = ["GuardDuty"]
        Severity = {
          Label = var.severity_labels
        }
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_to_sns" {
  rule      = aws_cloudwatch_event_rule.guardduty_findings.name
  target_id = "guardduty-sns"
  arn       = aws_sns_topic.guardduty_findings.arn

  input_transformer {
    input_paths = {
      account     = "$.detail.findings[0].AwsAccountId"
      region      = "$.detail.findings[0].Region"
      severity    = "$.detail.findings[0].Severity.Label"
      title       = "$.detail.findings[0].Title"
      description = "$.detail.findings[0].Description"
      type        = "$.detail.findings[0].Types[0]"
      firstSeen   = "$.detail.findings[0].FirstObservedAt"
    }
    input_template = "\"[GuardDuty] <title>\\n\\nAccount:    <account>\\nRegion:     <region>\\nSeverity:   <severity>\\nType:       <type>\\nFirst Seen: <firstSeen>\\n\\n<description>\""
  }
}

# =============================================================================
# SNS Topic
# =============================================================================

resource "aws_sns_topic" "guardduty_findings" {
  name = "${var.project}-guardduty-findings"
}

resource "aws_sns_topic_policy" "guardduty_findings" {
  arn = aws_sns_topic.guardduty_findings.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.guardduty_findings.arn
      }
    ]
  })
}
```

#### outputs.tf

```hcl
output "sns_topic_arn" {
  description = "GuardDuty findings SNS Topic ARN"
  value       = aws_sns_topic.guardduty_findings.arn
}

output "event_rule_arn" {
  description = "EventBridge Rule ARN for GuardDuty findings"
  value       = aws_cloudwatch_event_rule.guardduty_findings.arn
}
```

#### versions.tf

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}
```

---

### Step 2: env/management/guardduty_notification.tf — Module Call

```hcl
module "guardduty_notification" {
  source  = "../../modules/management/guardduty-notification"
  project = local.project
}
```

---

### Step 3: env/management/chatbot.tf — Slack Notifications (AWS Chatbot)

> **Preparation**: The Slack workspace integration must be configured in the AWS Chatbot console beforehand. Terraform cannot manage the workspace connection itself.

```hcl
# --- IAM Role for AWS Chatbot ---
resource "aws_iam_role" "chatbot_guardduty" {
  name = "${local.project}-chatbot-guardduty"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "chatbot.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "chatbot_guardduty" {
  role       = aws_iam_role.chatbot_guardduty.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# --- AWS Chatbot Slack Channel Configuration ---
resource "aws_chatbot_slack_channel_configuration" "guardduty" {
  configuration_name = "${local.project}-guardduty-findings"
  iam_role_arn       = aws_iam_role.chatbot_guardduty.arn
  slack_channel_id   = "<slack_channel_id>"
  slack_team_id      = "<slack_workspace_id>"
  sns_topic_arns     = [module.guardduty_notification.sns_topic_arn]
  logging_level      = "ERROR"
}
```

---

## Integration with GuardDuty Multi-Region Recipe

When using this SecurityHub approach, modify the [GuardDuty Multi-Region Management](guardduty-multiregion-setup.md) module calls as follows:

### What to Keep

All core GuardDuty resources remain unchanged:
- `aws_guardduty_detector`
- `aws_guardduty_detector_feature` (all features)
- `aws_guardduty_member`
- `aws_guardduty_organization_admin_account`
- `aws_guardduty_organization_configuration`
- `aws_guardduty_organization_configuration_feature` (all features)

### What to Remove

Remove ALL notification-related variables and resources from the `guardduty-region` module:

**Variables to remove:**
- `is_aggregation_region`
- `management_account_id`
- `enable_finding_forwarding`
- `forwarding_event_bus_arn`
- `forwarding_role_arn`

**Resources to remove:**
- `aws_sns_topic.guardduty_findings`
- `aws_sns_topic_policy.guardduty_findings`
- `aws_cloudwatch_event_bus.guardduty_findings`
- `aws_cloudwatch_event_bus_policy.guardduty_findings`
- `aws_cloudwatch_event_rule.guardduty_default_bus`
- `aws_cloudwatch_event_target.guardduty_default_bus_to_sns`
- `aws_cloudwatch_event_rule.guardduty_custom_bus`
- `aws_cloudwatch_event_target.guardduty_custom_bus_to_sns`
- `aws_iam_role.guardduty_eventbridge_forwarding`
- `aws_iam_role_policy.guardduty_eventbridge_forwarding`
- `aws_cloudwatch_event_rule.guardduty_forward`
- `aws_cloudwatch_event_target.guardduty_forward`

**Outputs to remove:**
- `sns_topic_arn`
- `event_bus_arn`
- `forwarding_role_arn`

### Simplified Module Calls

All regions use the same simple call — no `is_aggregation_region` / `enable_finding_forwarding` distinction:

```hcl
module "guardduty_<region>" {
  source                     = "../../modules/management/guardduty-region"
  delegated_admin_account_id = local.delegated_admin_account_id
  member_accounts            = local.member_accounts
  providers                  = { aws = aws.<region> }
}
```

---

## Notes & Tips

### SecurityHub Behavior

1. **Finding Aggregator replicates findings, not just metadata**
   - When `linking_mode = "ALL_REGIONS"` is set, findings from all linked regions are replicated to the aggregation region's SecurityHub. This replication triggers `Security Hub Findings - Imported` EventBridge events in the aggregation region, enabling a single rule to catch findings from all regions.

2. **No duplicate notifications**
   - Findings from the aggregation region itself are natively in SecurityHub and trigger one event. Findings from other regions are replicated and trigger one event. Each finding produces exactly one notification.

3. **New regions are covered automatically**
   - `ALL_REGIONS` includes future regions. When you enable GuardDuty in a new region and SecurityHub is active there, findings automatically flow to the aggregation region — no additional EventBridge rules or forwarding needed.

4. **SecurityHub must be enabled in each region**
   - The Finding Aggregator aggregates SecurityHub findings, not GuardDuty findings directly. GuardDuty auto-imports its findings into SecurityHub, but SecurityHub must be enabled in the region for this to work.

5. **ASFF format differs from native GuardDuty format**
   - The EventBridge event uses ASFF (AWS Security Finding Format) instead of the native GuardDuty event format. Field paths differ (e.g., `$.detail.findings[0].Severity.Label` instead of `$.detail.severity`). The `input_transformer` in this recipe uses ASFF paths.

### Terraform Implementation

1. **Finding Aggregator is a single global resource**
   - Only one `aws_securityhub_finding_aggregator` can exist per account. If already configured (e.g., by Control Tower), import it.

2. **Import command for existing Finding Aggregator**
   ```hcl
   import {
     to = module.guardduty_notification.aws_securityhub_finding_aggregator.this
     id = "<finding_aggregator_arn>"
   }
   ```
   Retrieve the ARN:
   ```bash
   aws securityhub list-finding-aggregators --region <aggregation_region> \
     --query 'FindingAggregators[0].FindingAggregatorArn' --output text
   ```

3. **SecurityHub Organization admin may already be designated**
   - If Control Tower is managing SecurityHub, the delegated admin is likely the Audit account, not the management account. Verify before adding `aws_securityhub_organization_admin_account`.

---

## Verification Steps

```bash
# 1. Format and validate
terraform fmt -recursive
terraform validate

# 2. Review plan
terraform plan

# 3. Apply
terraform apply

# 4. Verify Finding Aggregator is active
aws securityhub list-finding-aggregators \
  --region <aggregation_region> \
  --query 'FindingAggregators[0].{ARN:FindingAggregatorArn,Regions:RegionLinkingMode}' \
  --output table

# 5. Test with sample findings from a non-aggregation region
aws guardduty create-sample-findings \
  --detector-id <detector_id> \
  --finding-types UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration \
  --region <non_aggregation_region>
# -> Verify that a notification appears in the Slack channel
#    (the finding should flow: GuardDuty -> SecurityHub -> Aggregator -> EventBridge -> SNS -> Chatbot -> Slack)

# 6. Test from the aggregation region as well
aws guardduty create-sample-findings \
  --detector-id <detector_id> \
  --finding-types UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration \
  --region <aggregation_region>
# -> Verify notification arrives via the direct path (no cross-region needed)
```
