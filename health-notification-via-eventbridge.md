# AWS Health Notification via EventBridge — Terraform Construction Prompt

[日本語版](health-notification-via-eventbridge.ja.md)

## Overview

Build a notification pipeline that uses the **EventBridge us-west-2 aggregation** (available since November 2025) to capture account-specific AWS Health events from every region of the standard partition with a single rule (public events are not delivered this way, and global-service events go to us-east-1), then deliver them to Slack via a Knowledge Base–powered AI analysis pipeline.

### Why us-west-2?

AWS Health delivers each event to the impacted region and to a backup region. In the standard partition, **us-west-2** is the backup region for every other region (us-east-1 is the backup for us-west-2). A single EventBridge rule in us-west-2 therefore captures **account-specific** Health events from every region — no per-region rules or cross-region forwarding needed.

Two limits apply: **public events** (service-wide issues shown on the AWS Health Dashboard) are not delivered through this path, and **global-service events** (IAM, Route 53, CloudFront, billing) are published to us-east-1 — add a rule there if you need them.

### Comparison with Other Approaches

| Approach | Cross-Region | All Event Types | Real-Time | Complexity |
|---|---|---|---|---|
| **EventBridge us-west-2 (this recipe)** | **All regions (account-specific events)** | **All categories** | **Yes** | **Low** |
| SecurityHub Finding Aggregator | All regions | Security-only | Yes | Medium |
| Health Organizational View | All accounts (single EventBridge feed in the management / delegated administrator account) | All categories | Yes | Low |
| AWS Health Aware (AHA) | All regions | All types | Polling (delayed) | High |

> **Note**: SecurityHub only receives *security-related* Health events. Operational events (maintenance, service degradation, etc.) are NOT sent to SecurityHub. This recipe captures all event types.

### Terminology

| Term | Meaning |
|---|---|
| **aggregation region** | us-west-2 — where a single EventBridge rule captures account-specific Health events from all regions (backup delivery) |
| **processing region** | The region where Lambda, Bedrock KB, DynamoDB, and Scheduler run (e.g., `ap-northeast-1`) |
| **eventTypeCategory** | Health event classification: `issue`, `accountNotification`, `scheduledChange`, `investigation` |

---

## Architecture

```
[All Regions]
  AWS Health Event
      ↓ (also delivered to the backup region us-west-2)

[us-west-2]
  EventBridge Rule (source=aws.health)
      ↓ (cross-region target)

[Processing Region, e.g. ap-northeast-1]
  EventBridge (custom bus: health-events)
      ↓
  EventBridge Rule → SNS Topic
      ↓
  Triage Lambda
      ├── issue (open) → IMMEDIATE: KB + Claude → Slack
      ├── accountNotification → HOURLY: DynamoDB → hourly digest
      └── scheduledChange → DAILY: DynamoDB → daily digest (10:00 JST)

  EventBridge Scheduler (hourly/daily)
      → Digest Lambda → DynamoDB → KB + Claude batch → Slack digest
```

---

## Prerequisites

| Item | Description |
|---|---|
| **AWS Organizations** (multi-account only) | Organizational view enabled in the management account so that one account receives the Health feed for all accounts. Console enablement works on every support plan; the CLI/API requires Business, Enterprise On-Ramp or Enterprise Support. No Terraform resource exists — treat it as a manual prerequisite |
| **Processing region** | Region for Lambda/KB resources (e.g., `ap-northeast-1`) |
| **Slack webhook** | Slack Incoming Webhook URL for notifications |
| **Terraform providers** | Provider aliases for us-west-2 (aggregation) and processing region |
| **Bedrock access** | Claude Sonnet and Titan Embed v2 model access in the processing region |

---

## Event Classification (Batching Tiers)

| eventTypeCategory | statusCode | Tier | Notification |
|---|---|---|---|
| `issue` | `open` | IMMEDIATE | Instant AI analysis + Slack |
| `investigation` | any | IMMEDIATE | Instant AI analysis + Slack (AWS is investigating activity in your account) |
| `issue` | `closed` | DAILY | Daily digest |
| `accountNotification` | any | HOURLY | Hourly digest |
| `scheduledChange` | `upcoming` | DAILY | Daily digest (10:00 JST) |
| `scheduledChange` | `open` / `closed` | DAILY | Daily digest |

---

## Directory Structure

```
terraform/
├── env/management/
│   ├── backend.tf
│   ├── locals.tf
│   └── health_knowledge_analysis.tf     # Module call
│
└── modules/health-knowledge-analysis/
    ├── eventbridge.tf                    # us-west-2 rule + cross-region + processing region rule + SNS
    ├── lambda.tf                         # Triage Lambda + SNS subscription
    ├── digest_lambda.tf                  # Digest Lambda + Scheduler permissions
    ├── knowledge_base.tf                 # Bedrock KB + S3 Vectors + data sources
    ├── s3.tf                             # S3 bucket (docs + history)
    ├── dynamodb.tf                       # Finding queue table
    ├── scheduler.tf                      # EventBridge Scheduler (hourly + daily) + DLQ
    ├── iam.tf                            # Triage Lambda IAM
    ├── variables.tf
    ├── outputs.tf
    ├── locals.tf
    ├── data.tf
    └── src/
        ├── common.py                     # Shared utilities (KB, Claude, Slack, sanitize)
        ├── index.py                      # Triage handler
        └── digest.py                     # Digest handler
```

---

## Build Steps

### Step 1: eventbridge.tf — Cross-Region Event Capture

The module requires **two providers**: the default provider for the processing region and a `us_west_2` alias for the aggregation region.

```hcl
# --- us-west-2: Capture account-specific Health events from all regions ---
resource "aws_cloudwatch_event_rule" "health_all_regions" {
  provider    = aws.us_west_2
  name        = "${var.project_name}-health-all-regions"
  description = "Capture account-specific AWS Health events from all regions via the us-west-2 backup delivery"

  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail-type = ["AWS Health Event", "AWS Health Abuse Event"]
  })
}

# --- Cross-region forwarding to processing region ---
resource "aws_cloudwatch_event_bus" "health_events" {
  name = "${var.project_name}-health-events"
}

resource "aws_cloudwatch_event_bus_policy" "health_events" {
  event_bus_name = aws_cloudwatch_event_bus.health_events.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCrossRegionPutEvents"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "events:PutEvents"
      Resource  = aws_cloudwatch_event_bus.health_events.arn
    }]
  })
}

resource "aws_iam_role" "eventbridge_forwarding" {
  provider = aws.us_west_2
  name     = "${var.project_name}-health-eb-forwarding"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_forwarding" {
  provider = aws.us_west_2
  name     = "${var.project_name}-health-eb-forwarding"
  role     = aws_iam_role.eventbridge_forwarding.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "events:PutEvents"
      Resource = aws_cloudwatch_event_bus.health_events.arn
    }]
  })
}

resource "aws_cloudwatch_event_target" "forward_to_processing" {
  provider  = aws.us_west_2
  rule      = aws_cloudwatch_event_rule.health_all_regions.name
  target_id = "forward-health-events"
  arn       = aws_cloudwatch_event_bus.health_events.arn
  role_arn  = aws_iam_role.eventbridge_forwarding.arn
}

# --- Processing region: custom bus → SNS ---
resource "aws_cloudwatch_event_rule" "health_to_sns" {
  name           = "${var.project_name}-health-to-sns"
  event_bus_name = aws_cloudwatch_event_bus.health_events.name
  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail-type = ["AWS Health Event", "AWS Health Abuse Event"]
  })
}

resource "aws_cloudwatch_event_target" "health_to_sns" {
  rule           = aws_cloudwatch_event_rule.health_to_sns.name
  event_bus_name = aws_cloudwatch_event_bus.health_events.name
  target_id      = "health-sns"
  arn            = aws_sns_topic.health_events.arn
}

resource "aws_sns_topic" "health_events" {
  name = "${var.project_name}-health-events"
}

resource "aws_sns_topic_policy" "health_events" {
  arn = aws_sns_topic.health_events.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgePublish"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.health_events.arn
    }]
  })
}
```

### Step 2: Lambda, Knowledge Base, DynamoDB, Scheduler

These follow the same pattern as [SecurityHub Finding Aggregator](securityhub-finding-aggregator.md) with GuardDuty Knowledge Analysis. Key differences in the Lambda code:

**Event parsing** — Health events use a different structure:
```python
def parse_health_event(message_str):
    event = json.loads(message_str)
    detail = event.get("detail", {})
    return {
        "event_arn": detail.get("eventArn", ""),
        "service": detail.get("service", ""),
        "event_type_code": detail.get("eventTypeCode", ""),
        "event_type_category": detail.get("eventTypeCategory", ""),
        "region": detail.get("eventRegion", ""),          # impacted region ("region" at the top level is the delivery region)
        "status_code": detail.get("statusCode", ""),
        "start_time": detail.get("startTime", ""),
        "end_time": detail.get("endTime", ""),
        "description": detail.get("eventDescription", [{}])[0].get("latestDescription", ""),
        "affected_entities": detail.get("affectedEntities", []),
        "account_id": detail.get("affectedAccount", event.get("account", "")),  # top-level "account" is the receiving account under organizational view
        "communication_id": detail.get("communicationId", ""),
        "page": detail.get("page", "1"),
        "total_pages": detail.get("totalPages", "1"),
    }
```

**Severity classification** — Based on `eventTypeCategory` + `statusCode`:
```python
def classify_health_event(event_info):
    category = event_info["event_type_category"]
    status = event_info["status_code"]
    if category == "issue" and status == "open":
        return "IMMEDIATE"
    elif category == "investigation":
        return "IMMEDIATE"
    elif category == "accountNotification":
        return "HOURLY"
    return "DAILY"
```

**System prompt** — Adapted for Health event analysis:
```python
SYSTEM_PROMPT = (
    "あなたはAWSインフラ運用のエキスパートです。"
    "AWS Health イベントを分析し、運用チームに対して影響評価と対応手順を日本語で提供してください。..."
)
```

### Step 3: Module Call

```hcl
module "health_knowledge_analysis" {
  source = "../../modules/health-knowledge-analysis"

  environment        = local.environment
  slack_webhook_path = var.health_analysis_slack_webhook_path

  providers = {
    aws           = aws            # ap-northeast-1
    aws.us_west_2 = aws.us_west_2  # us-west-2
  }
}
```

---

## Notes & Tips

### AWS Health Behavior

1. **us-west-2 receives account-specific events from all regions (backup delivery)**
   - You no longer need per-region EventBridge rules for account-specific Health events
   - us-west-2 is the backup region for all other regions; us-east-1 is the backup for us-west-2 only
   - Public events are not included. If you need them, keep a rule in each region where you have resources
   - Backup copies carry `detail.backupEvent = true` — filter or deduplicate if the same account also has per-region rules

2. **Global events (IAM, Route53, CloudFront) are published to us-east-1**
   - For complete coverage, add a secondary rule in us-east-1 for global service events
   - us-west-2 does not receive them: us-east-1 is the backup for us-west-2, not the other way round

3. **SecurityHub only receives security-related Health events**
   - Operational events (maintenance, deprecation, service issues) bypass SecurityHub
   - This recipe captures ALL event types via direct EventBridge integration

4. **Health organizational view aggregates accounts, not regions**
   - When enabled in the management account (optionally delegated to a member account), that account receives a single EventBridge feed of Health events for every account in the organization. Combine it with the us-west-2 rule in that account for multi-account, multi-region coverage
   - Console enablement works on every support plan. The CLI/API (`aws health enable-health-service-access-for-organization --region us-east-1`) requires Business, Enterprise On-Ramp or Enterprise Support. There is no Terraform resource for it

### Event Deduplication

- `eventArn` is not unique across accounts or regions. Key event state on `affectedAccount` + `eventArn`, and drop duplicate deliveries (backup copies, retries) on `affectedAccount` + `communicationId`, which also carries the page number for paginated events
- Events may be updated (statusCode changes from `upcoming` → `open` → `closed`)
- Use conditional UpdateItem to keep the latest version, similar to GuardDuty finding updates

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

# 4. Verify EventBridge rule in us-west-2
aws events list-rules --region us-west-2 \
  --query "Rules[?contains(Name, 'health')]"

# 5. Verify cross-region target
aws events list-targets-by-rule \
  --rule <rule-name> --region us-west-2

# 6. Test with a sample Health event (wait for a real event or use EventBridge test event feature)
```
