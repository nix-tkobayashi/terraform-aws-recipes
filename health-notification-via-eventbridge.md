# AWS Health Notification via EventBridge — Terraform Construction Prompt

[日本語版](health-notification-via-eventbridge.ja.md)

## Overview

Build a notification pipeline that uses the **EventBridge us-west-2 aggregation** (available since November 2025) to capture all AWS Health events across all regions with a single rule, then deliver them to Slack via a Knowledge Base–powered AI analysis pipeline.

### Why us-west-2?

Since November 2025, AWS Health dual-publishes all events to **us-west-2** in addition to the impacted region. A single EventBridge rule in us-west-2 captures Health events from every region — no per-region rules or cross-region forwarding needed.

### Comparison with Other Approaches

| Approach | Cross-Region | All Event Types | Real-Time | Complexity |
|---|---|---|---|---|
| **EventBridge us-west-2 (this recipe)** | **All regions** | **All types** | **Yes** | **Low** |
| SecurityHub Finding Aggregator | All regions | Security-only | Yes | Medium |
| Health Organizational View | API/Console only | All types | Dashboard only | Low |
| AWS Health Aware (AHA) | All regions | All types | Polling (delayed) | High |

> **Note**: SecurityHub only receives *security-related* Health events. Operational events (maintenance, service degradation, etc.) are NOT sent to SecurityHub. This recipe captures all event types.

### Terminology

| Term | Meaning |
|---|---|
| **aggregation region** | us-west-2 — where the EventBridge rule captures all Health events |
| **processing region** | The region where Lambda, Bedrock KB, DynamoDB, and Scheduler run (e.g., `ap-northeast-1`) |
| **eventTypeCategory** | Health event classification: `issue`, `accountNotification`, `scheduledChange` |

---

## Architecture

```
[All Regions]
  AWS Health Event
      ↓ (automatically dual-published to us-west-2 since Nov 2025)

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
| **AWS Organizations** | Organizational Health view enabled for cross-account event visibility |
| **Processing region** | Region for Lambda/KB resources (e.g., `ap-northeast-1`) |
| **Slack webhook** | Slack Incoming Webhook URL for notifications |
| **Terraform providers** | Provider aliases for us-west-2 (aggregation) and processing region |
| **Bedrock access** | Claude Sonnet and Titan Embed v2 model access in the processing region |

---

## Event Classification (Batching Tiers)

| eventTypeCategory | statusCode | Tier | Notification |
|---|---|---|---|
| `issue` | `open` | IMMEDIATE | Instant AI analysis + Slack |
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
# --- us-west-2: Capture all Health events ---
resource "aws_cloudwatch_event_rule" "health_all_regions" {
  provider    = aws.us_west_2
  name        = "${var.project_name}-health-all-regions"
  description = "Capture all AWS Health events from all regions via us-west-2 aggregation"

  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail-type = ["AWS Health Event"]
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
    detail-type = ["AWS Health Event"]
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
        "region": detail.get("region", ""),
        "status_code": detail.get("statusCode", ""),
        "start_time": detail.get("startTime", ""),
        "end_time": detail.get("endTime", ""),
        "description": detail.get("eventDescription", [{}])[0].get("latestDescription", ""),
        "affected_entities": detail.get("affectedEntities", []),
        "account_id": event.get("account", ""),
    }
```

**Severity classification** — Based on `eventTypeCategory` + `statusCode`:
```python
def classify_health_event(event_info):
    category = event_info["event_type_category"]
    status = event_info["status_code"]
    if category == "issue" and status == "open":
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

1. **us-west-2 receives ALL regional events since November 2025**
   - You no longer need per-region EventBridge rules for Health events
   - us-east-1 serves as a backup for us-west-2, and us-west-2 serves as a backup for all other regions

2. **Global events (IAM, Route53, CloudFront) are published to us-east-1**
   - For complete coverage, add a secondary rule in us-east-1 for global service events
   - Or rely on us-west-2 which also receives them as backup

3. **SecurityHub only receives security-related Health events**
   - Operational events (maintenance, deprecation, service issues) bypass SecurityHub
   - This recipe captures ALL event types via direct EventBridge integration

4. **Health Organizational View is complementary**
   - Enable it for dashboard visibility, but it does not emit EventBridge events
   - Enable via CLI: `aws health enable-health-service-access-for-organization --region us-east-1`

### Event Deduplication

- Health events have a unique `eventArn` — use this as the DynamoDB partition key
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
