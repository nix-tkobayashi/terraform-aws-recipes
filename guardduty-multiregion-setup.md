# GuardDuty Multi-Region Management — Terraform Construction Prompt

[日本語版](guardduty-multiregion-setup.ja.md)

## Overview

Build a configuration that enables GuardDuty across target regions within an AWS Organizations environment, managed from a single Terraform workspace (management environment). Findings of MEDIUM severity or higher are delivered via email notifications.

### Terminology

| Term | Meaning |
|---|---|
| **management account** | The AWS Organizations management account. The organization creator that has authority to designate delegated administrators. |
| **delegated administrator** | The GuardDuty delegated administrator account. Manages Detectors, members, and Organization configuration. |
| **aggregation region** | The region where EventBridge / SNS notifications are aggregated. |

> **Assumption**: This specification assumes the management account also serves as the GuardDuty delegated administrator. If delegating to a separate account, you will need a separate design with distinct providers for the management account and delegated admin account (via `assume_role`).

---

## Prerequisites

Confirm or provide the following information before starting:

| Item | Description |
|---|---|
| **management account ID** | AWS Organizations management account ID |
| **delegated admin account ID** | GuardDuty delegated administrator (same as management account in this spec) |
| **Member account list** | Map format: `{ "account_id" = "root_email" }` |
| **Target regions** | Regions where GuardDuty will be enabled (define per project; see sample below) |
| **Aggregation region** | Region where EventBridge / SNS notifications are aggregated (e.g., `ap-northeast-1`) |
| **Notification email** | Email address for GuardDuty Finding notifications |
| **Terraform backend** | S3 bucket name, key, and region |
| **Existing Detector IDs** | If GuardDuty is already enabled in a region, its Detector ID (`aws guardduty list-detectors --region <region>`) |

### Cost Considerations

Enabling GuardDuty across all regions and accounts incurs charges for protection features such as EBS Malware Protection and Runtime Monitoring. Review the AWS pricing page for cost impact before applying.

---

## Directory Structure

```
terraform/
├── env/management/                             # Single tfstate managing all regions
│   ├── backend.tf                              # Provider aliases + S3 backend
│   ├── locals.tf                               # project / environment / account IDs / regions
│   ├── guardduty.tf                            # import + module calls + outputs
│   ├── guardduty-notifications.tf              # EventBridge aggregation → SNS → Email
│
└── modules/management/guardduty-region/         # GuardDuty configuration for one region
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    └── versions.tf
```

---

## Build Steps

### Step 1: modules/management/guardduty-region/ — Shared Module

Encapsulate per-region GuardDuty configuration into a module. This module is called once per target region to deploy identical settings across all regions.

#### variables.tf

```hcl
variable "delegated_admin_account_id" {
  description = "AWS account ID to designate as GuardDuty delegated administrator"
  type        = string
}

variable "member_accounts" {
  description = "GuardDuty member accounts (key: account_id, value: root email)"
  type        = map(string)
  default     = {}
}
```

#### main.tf

Include the following resources:

```hcl
# --- Detector ---
resource "aws_guardduty_detector" "this" {
  enable                       = true
  finding_publishing_frequency = "SIX_HOURS"
}

# --- Detector Features (protection for the delegated admin account itself) ---
# Define each feature individually via aws_guardduty_detector_feature:
#   S3_DATA_EVENTS          → ENABLED
#   EKS_AUDIT_LOGS          → ENABLED
#   EBS_MALWARE_PROTECTION  → ENABLED
#   RDS_LOGIN_EVENTS        → ENABLED
#   LAMBDA_NETWORK_LOGS     → ENABLED
#   EKS_RUNTIME_MONITORING  → DISABLED (additional: EKS_ADDON_MANAGEMENT=DISABLED)
#   RUNTIME_MONITORING      → ENABLED
#     additional: EKS_ADDON_MANAGEMENT=DISABLED
#     additional: ECS_FARGATE_AGENT_MANAGEMENT=ENABLED
#     additional: EC2_AGENT_MANAGEMENT=DISABLED

# --- Member Account Registration ---
resource "aws_guardduty_member" "this" {
  for_each = var.member_accounts

  detector_id                = aws_guardduty_detector.this.id
  account_id                 = each.key
  email                      = each.value
  invite                     = false
  disable_email_notification = true

  lifecycle {
    # Under Organizations, AWS controls invite/disassociate.
    # Ignoring these fields prevents perpetual diffs on every plan.
    ignore_changes = [email, disable_email_notification, invite]
  }
}

# --- Organizations Delegated Administrator ---
resource "aws_guardduty_organization_admin_account" "this" {
  admin_account_id = var.delegated_admin_account_id
}

# --- Organizations Auto-Enable ---
resource "aws_guardduty_organization_configuration" "this" {
  auto_enable_organization_members = "ALL"
  detector_id                      = aws_guardduty_detector.this.id
  depends_on                       = [aws_guardduty_organization_admin_account.this]
}

# --- Organizations Feature Policy ---
# Define via aws_guardduty_organization_configuration_feature:
#   S3_DATA_EVENTS          → auto_enable = "ALL"
#   EBS_MALWARE_PROTECTION  → auto_enable = "ALL"
#   RDS_LOGIN_EVENTS        → auto_enable = "ALL"
#   LAMBDA_NETWORK_LOGS     → auto_enable = "NONE"
#   EKS_AUDIT_LOGS          → auto_enable = "NONE"
#   EKS_RUNTIME_MONITORING  → auto_enable = "NONE"
#   RUNTIME_MONITORING      → auto_enable = "ALL"
#     additional: ECS_FARGATE_AGENT_MANAGEMENT = "ALL"
#     additional: EC2_AGENT_MANAGEMENT = "NONE"
#     additional: EKS_ADDON_MANAGEMENT = "NONE"
```

#### outputs.tf

```hcl
output "detector_id" {
  description = "GuardDuty Detector ID"
  value       = aws_guardduty_detector.this.id
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

### Step 2: env/management/backend.tf — Provider Aliases

Define provider aliases for each target region.

```hcl
terraform {
  backend "s3" {
    bucket = "<s3_bucket_name>"
    key    = "management/terraform.tfstate"
    region = "<aggregation_region>"
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "<version>" }
  }
}

# Default provider (aggregation region)
provider "aws" {
  region = "<aggregation_region>"
  default_tags {
    tags = {
      Project     = local.project
      Environment = local.environment
      ManagedBy   = "Terraform"
    }
  }
}

# Define an alias for each target region (except the aggregation region):
# Format:
#   provider "aws" {
#     alias  = "us_east_1"
#     region = "us-east-1"
#     default_tags { tags = { Project = local.project, Environment = local.environment, ManagedBy = "Terraform" } }
#   }
```

---

### Step 3: env/management/locals.tf — Shared Variables

Consolidate project and account information in `locals.tf`.

```hcl
locals {
  project     = "<project_name>"
  environment = "management"

  delegated_admin_account_id = "<delegated_admin_account_id>"

  member_accounts = {
    "<account_id>" = "<root_email>"
    # ... all member accounts
  }

  aggregation_region = "<aggregation_region>"

  # Existing Detector IDs (only needed for regions where GuardDuty is already enabled)
  detector_ids = {
    ap_northeast_1 = "<detector_id>"
    us_east_1      = "<detector_id>"
    # ... per region
  }
}
```

---

### Step 4: env/management/guardduty.tf — Module Calls

#### Import Blocks (importing existing resources)

For regions where GuardDuty is already enabled, define the following imports.

**Core resources** (3 per region):

```hcl
import {
  to = module.guardduty_<region>.aws_guardduty_detector.this
  id = local.detector_ids.<region>
}
import {
  to = module.guardduty_<region>.aws_guardduty_organization_admin_account.this
  id = local.delegated_admin_account_id
}
import {
  to = module.guardduty_<region>.aws_guardduty_organization_configuration.this
  id = local.detector_ids.<region>
}
```

**Member accounts** (if already registered):

```hcl
import {
  to = module.guardduty_<region>.aws_guardduty_member.this["<account_id>"]
  id = "${local.detector_ids.<region>}:<account_id>"
}
```

**Feature resources** (existing Detector Feature / Organization Configuration Feature):

```hcl
# aws_guardduty_detector_feature does not require import (Terraform manages diffs automatically)
# aws_guardduty_organization_configuration_feature likewise
# However, if there are significant diffs from existing settings, review plan output carefully
```

> **Note**: `detector_feature` / `organization_configuration_feature` are managed by Terraform via diff based on the Detector ID, so import is typically unnecessary. Always verify during `plan` that no unintended changes are introduced.

#### Moved Blocks (only when migrating from flat resources to modules)

If flat resources (e.g., `aws_guardduty_detector.ap_northeast_1`) already exist in the Terraform state, use `moved` blocks to migrate without destroying state:

```hcl
moved {
  from = aws_guardduty_detector.<region>
  to   = module.guardduty_<region>.aws_guardduty_detector.this
}
```

**Important**: `import` and `moved` are mutually exclusive. Do not use both for the same resource.

#### Module Calls

Call the module for each target region:

```hcl
module "guardduty_<aggregation_region>" {
  source                     = "../../modules/management/guardduty-region"
  delegated_admin_account_id = local.delegated_admin_account_id
  member_accounts            = local.member_accounts
  providers                  = { aws = aws }  # Default provider (aggregation region)
}

module "guardduty_<other_region>" {
  source                     = "../../modules/management/guardduty-region"
  delegated_admin_account_id = local.delegated_admin_account_id
  member_accounts            = local.member_accounts
  providers                  = { aws = aws.<other_region> }
}

# ... repeat for all target regions
```

#### Outputs

Output the Detector ID for each region:

```hcl
output "guardduty_detector_id_<region>" {
  description = "GuardDuty Detector ID (<region>)"
  value       = module.guardduty_<region>.detector_id
}
```

---

### Step 5: env/management/guardduty-notifications.tf — Email Notifications

Aggregate MEDIUM+ (severity >= 4.0) findings from all regions to the aggregation region and send email notifications. Notification resources are created in the delegated admin account (= management account).

#### Architecture

```
[Aggregation Region]
  default EventBus → EventBridge Rule → SNS Topic → Email
  custom  EventBus "guardduty-findings" → EventBridge Rule → SNS Topic → Email

[Other Regions]
  default EventBus → EventBridge Rule → Aggregation Region custom EventBus (forwarding)
```

#### Required Resources

1. **SNS Topic + Email Subscription** (aggregation region)
   - Topic: `guardduty-findings`
   - Topic Policy: Allow `sns:Publish` from `events.amazonaws.com`
   - Subscription: `protocol = "email"`, `endpoint = "<notification_email>"`
   - **Note**: After apply, a confirmation email is sent to the notification address. Manual approval is required.

2. **Custom Event Bus** (aggregation region)
   - Name: `guardduty-findings`
   - Bus Policy: Allow `events:PutEvents` from the same account

3. **EventBridge Rule: aggregation region default bus → SNS**
   - event_pattern: `source=aws.guardduty, detail-type=GuardDuty Finding, detail.severity >= 4`
   - target: SNS Topic
   - input_transformer to format output (Account/Region/Severity/Type/Description + console link)

4. **EventBridge Rule: custom bus → SNS**
   - Routes findings forwarded from other regions to SNS
   - Uses the same input_transformer

5. **IAM Role** (IAM is a global service, but created under the default provider (aggregation region) in Terraform)
   - Trust policy: `events.amazonaws.com`
   - Permission: `events:PutEvents` on `arn:aws:events:<aggregation_region>:<account>:event-bus/guardduty-findings`

6. **Forwarding rules per region** (one per region, excluding the aggregation region)
   - Create EventBridge Rule + Target using each provider alias
   - event_pattern: severity >= 4.0 filter
   - target: aggregation region custom event bus ARN
   - role_arn: IAM Role above

#### Input Transformer Template Example

```hcl
input_transformer {
  input_paths = {
    account     = "$.account"
    region      = "$.region"
    id          = "$.detail.id"
    severity    = "$.detail.severity"
    type        = "$.detail.type"
    title       = "$.detail.title"
    description = "$.detail.description"
  }
  input_template = "\"[GuardDuty] <title>\\n\\nAccount:  <account>\\nRegion:   <region>\\nSeverity: <severity>\\nType:     <type>\\n\\n<description>\\n\\nhttps://console.aws.amazon.com/guardduty/home?region=<region>#/findings?search=id%3D<id>\""
}
```

---

## Notes & Tips

### AWS Behavior

1. **`aws_guardduty_member` lifecycle ignore_changes is required**
   - Under Organizations, AWS controls invite/email for members. Without `ignore_changes = [email, disable_email_notification, invite]`, perpetual diffs appear on every plan.

2. **`aws_guardduty_organization_admin_account` requires management account credentials**
   - Apply using the Organizations management account credentials, not the delegated admin account.

3. **Import blocks are consumed on the first plan/apply**
   - You may remove import blocks after the initial apply (leaving them is also harmless).

4. **Only one Detector can exist per region**
   - If already enabled, import it. Attempting to create a new one will result in an error.

5. **EKS_RUNTIME_MONITORING and RUNTIME_MONITORING are mutually exclusive**
   - RUNTIME_MONITORING is the successor. Set EKS_RUNTIME_MONITORING to DISABLED and control EKS addon management via the RUNTIME_MONITORING feature instead.

6. **SNS Email Subscription requires manual confirmation**
   - After `terraform apply`, a confirmation email is sent to the notification address. Notifications will not be delivered until confirmed.

### Terraform Implementation

1. **`for_each` cannot be used for multi-region expansion**
   - Provider aliases cannot be passed via `for_each` / `count`, so module calls must be explicitly written for each target region.

2. **`moved` and `import` are mutually exclusive**
   - Use `moved` for resources already in Terraform state; use `import` for resources that exist in AWS but not in state.

3. **Apply order**
   - On the first run, verify import/moved results with `terraform plan` before applying.
   - The total number of resources (regions × resources per region) can be large — review plan output carefully.

---

## Target Regions

Define target regions per project. Use the following command to list ENABLED_BY_DEFAULT regions:

```bash
aws account list-regions --region-opt-status-contains ENABLED_BY_DEFAULT \
  --query 'Regions[].RegionName' --output text
```

### Sample: 17 ENABLED_BY_DEFAULT Regions

```
ap-northeast-1, ap-northeast-2, ap-northeast-3,
ap-south-1, ap-southeast-1, ap-southeast-2,
ca-central-1,
eu-central-1, eu-north-1, eu-west-1, eu-west-2, eu-west-3,
sa-east-1,
us-east-1, us-east-2, us-west-1, us-west-2
```

> **Note**: GuardDuty supports regions beyond the 17 listed above (e.g., ap-southeast-3, ca-west-1, eu-central-2). Whether to include opt-in regions should be decided based on project requirements.

---

## Verification Steps

After build completion, verify with the following steps:

```bash
# 1. Format and validate
terraform fmt -recursive
terraform validate

# 2. Review plan (verify import/moved results)
terraform plan

# 3. Apply
terraform apply

# 4. Confirm SNS Email Subscription
#    Click "Confirm subscription" in the confirmation email sent to the notification address

# 5. Test notifications with sample findings
aws guardduty create-sample-findings \
  --detector-id <detector_id> \
  --finding-types UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration \
  --region <aggregation_region>
```

---

## Bulk Retrieval of Existing Detector IDs

```bash
for region in $(aws account list-regions \
  --region-opt-status-contains ENABLED_BY_DEFAULT \
  --query 'Regions[].RegionName' --output text); do
  id=$(aws guardduty list-detectors --region "$region" --query 'DetectorIds[0]' --output text 2>/dev/null)
  key=$(echo "$region" | tr '-' '_')
  echo "    ${key} = \"${id}\""
done
```
