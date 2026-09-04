# Security Notification Topology — Terraform examples

Reference implementations for the three account layouts described in
[security-notification-topology.md](../../security-notification-topology.md).
Shared modules live in `modules/`; each case is a thin root that wires them to
the right account and region.

| Root | Layout | Status |
|---|---|---|
| `case1-delegated-security-account/management` | Management account: delegations only | validated |
| `case1-delegated-security-account/security` | Security tooling account: aggregation, detection, notification | validated |
| `case2-management-account` | Management account doubles as tooling account (local configuration) | validated |
| `case3-single-member` | One member account, no delegation | validated; mirrors a production layout |

## Modules

| Module | Purpose |
|---|---|
| `notification-topic` | SNS topic (EventBridge publish with `aws:SourceAccount`) and an SQS dead-letter queue for EventBridge targets, per region |
| `securityhub-region` | Enable Security Hub CSPM in one region, subscribe standards, optionally disable global-resource controls (non-home regions) |
| `securityhub-home` | Finding aggregator, the notification rules (controls: severity-filtered, Inspector excluded by default; GuardDuty: all severities; both `Workflow.Status = NEW`, `RecordState = ACTIVE`) and the Lambda that marks notified findings `NOTIFIED` |
| `securityhub-central-config` | Central configuration policy (case 1 only) |
| `guardduty-region` | Detector with every optional feature declared ENABLED or DISABLED; optional organization auto-enable for delegated administrators |
| `inspector-region` | Inspector enablement; optional organization defaults |
| `health-route` | Health EventBridge rule (both detail-types) to the regional topic, with backup-event and impacted-region filters to avoid double delivery |

## Validate

```bash
cd case3-single-member          # or any other root
terraform init -backend=false
terraform validate
```

Backends, account ids, Slack ids and webhooks are intentionally not committed;
copy `terraform.tfvars.example` to `terraform.tfvars` and fill it in.

## Adding regions

Provider aliases cannot be passed through `for_each`, so each region needs its
own `provider` block and one module block per module. Keep the regions where
GuardDuty is enabled equal to `linked_regions`; findings in an unlinked region
are never notified.

## Not included

- An investigation pipeline (Lambda → webhook → DevOps Agent or Bedrock). The
  topics are exposed as outputs so a consumer can subscribe; see the Health and
  Security Hub recipes for a Knowledge Base based example.
- Enabling AWS Health organizational view (no Terraform resource; console on
  any support plan, CLI/API on Business or higher).
- Deduplication of paginated Health events (`communicationId`) — only needed
  when a consumer stores events.
