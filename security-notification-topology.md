# Security Notification Topology — Choosing Where Findings Are Aggregated

[日本語版](security-notification-topology.ja.md) · [Diagram / matrices (HTML)](docs/security-notification-topology.html) · [Terraform examples](examples/security-notification-topology/)

## Overview

Security Hub, GuardDuty, Inspector and AWS Health each raise findings or events in the account and region where something happened. Getting them to one Slack channel (or one investigation pipeline) means deciding **which account** and **which region** the EventBridge rules and SNS topics live in. This guide gives that decision for three account layouts and shows, per account × region × service, which AWS mechanism moves the data.

The three recipes in this repository are building blocks for the topologies below:

| Building block | Recipe |
|---|---|
| Multi-region GuardDuty (detectors, features, Organizations) | [GuardDuty Multi-Region Management](guardduty-multiregion-setup.md) |
| One notification rule fed by Security Hub cross-region aggregation | [SecurityHub Finding Aggregator](securityhub-finding-aggregator.md) |
| AWS Health capture (us-west-2 backup delivery, AI digest) | [AWS Health Notification via EventBridge](health-notification-via-eventbridge.md) |

Scope: Security Hub **CSPM** (the finding-aggregation service). The newer Security Hub has different delegated-administrator rules; they are noted where relevant. Regions used in the examples: `ap-northeast-1` as home and `us-east-1` for global-service events.

---

## The four mechanisms

These are independent features, not one pipeline. A finding may traverse several of them; a Health event traverses only the last one.

| Mechanism | Crosses | What it is | Services |
|---|---|---|---|
| **Delegation** | Accounts | The Organizations management account designates a delegated administrator. Member findings are replicated into the administrator account **in the same region**. For Health, organizational view gives one EventBridge feed for every account | Security Hub, GuardDuty, Inspector (delegated admin); Health (organizational view, optionally delegated) |
| **Aggregation** | Regions | Security Hub cross-region aggregation replicates findings from linked regions to the home region. Only Security Hub has this | Security Hub |
| **Integration** | Services | Security Hub imports findings from GuardDuty and Inspector (all findings) and from Health (security-related events only, mostly MEDIUM) in the same account and region | Security Hub ← GuardDuty / Inspector / Health |
| **Direct** | — | An EventBridge rule publishes to an SNS topic in its own region. Notification paths exist only where a direct rule is placed | All |

Consequences that drive the design:

- GuardDuty and Inspector reach the home region through **integration → aggregation**, so no native GuardDuty EventBridge rule is needed. Keeping both paths notifies each finding twice.
- Health has **no aggregation** and only a partial integration, so Health needs a direct rule in every region that receives events: the regions that host workloads, `us-east-1` for global services (IAM, Route 53, CloudFront, billing), and optionally `us-west-2`, which receives account-specific events from every region as backup delivery. Both `detail-type` values (`AWS Health Event`, `AWS Health Abuse Event`) must be matched.
- Inspector findings reach the home region the same way as GuardDuty, but the examples exclude `ProductName = Inspector` from Slack by default: CVE findings arrive in bulk and are better reviewed in the console. Remove it from `excluded_product_names` to notify HIGH / CRITICAL vulnerabilities too.
- `Security Hub Findings - Imported` fires on every import **and update**. Filter on `Workflow.Status = NEW` and `RecordState = ACTIVE`, and set the status to `NOTIFIED` after the first notification when you need one notification per failure episode (Security Hub resets `NOTIFIED` to `NEW` when compliance goes PASSED → FAILED again).

---

## Choosing a case

```
Can the Organizations management account designate delegated administrators for you?
├─ no  → Case 3: single member account
└─ yes → Can a dedicated security account be created (or reused)?
         ├─ yes → Case 1: delegated administrator = security tooling account   (recommended)
         └─ no  → Case 2: management account = security tooling account         (works, not recommended)
```

Case 2 is not recommended by AWS: SCPs do not apply to the management account, and the account should hold only tasks that require it. It is also **incompatible with Security Hub central configuration** (the management account cannot be the delegated administrator there), so member accounts must be configured region by region.

---

## Case 1 — Delegated administrator = security tooling account (recommended)

| Account | Region | Security Hub | GuardDuty / Inspector | AWS Health | Notification path |
|---|---|---|---|---|---|
| Management | all | Designates the security account as delegated administrator (**delegation**). Does not enable Security Hub itself | Designates the same account per region (**delegation**) | Enables organizational view (console works on every support plan) and registers the security account as Health delegated administrator (**delegation**) | none |
| Security tooling | `ap-northeast-1` (home) | Administrator. Receives every member's Tokyo findings (**delegation**); `us-east-1` findings arrive by **aggregation**. Central configuration policies enable Security Hub and standards in all members | Administrator. Receives member findings (**delegation**); findings flow to Security Hub (**integration**) | Organizational view feed for Tokyo-originated events | **Direct**: Security Hub rule (severity / workflow filters) + Health rule → SNS Tokyo → Chatbot / Lambda |
| Security tooling | `us-east-1` (linked) | Administrator. Findings replicate to Tokyo (**aggregation**); no rule here | Administrator; **integration** → **aggregation** | Organizational view feed for global-service and `us-east-1` events (plus `us-west-2` backups) | **Direct**: Health rule only → SNS us-east-1 → Chatbot / Lambda (cross-region subscription) |
| Members (dev, prod, …) | each | Member. Enabled and configured by the central configuration policy. Findings replicate to the administrator (**delegation**) | Member, auto-enabled. **Integration** → **delegation** | Event source | none |

Terraform layout: two roots with separate state, `management/` (delegations only) and `security/` (aggregation, detection, notification). Provider aliases are needed per **account × region**, each assuming a dedicated role in its account.

## Case 2 — Management account = security tooling account (when unavoidable)

| Account | Region | Security Hub | GuardDuty / Inspector | AWS Health | Notification path |
|---|---|---|---|---|---|
| Management = tooling | `ap-northeast-1` (home) | Designates itself (**delegation**, local configuration only; the account must enable Security Hub manually). Receives member findings; `us-east-1` by **aggregation**. No configuration policies | Designates itself (**delegation**, documented as not recommended). Auto-enable per region. **Integration** | Organizational view stays in the management account — no delegation needed | **Direct**: Security Hub + Health rules → SNS Tokyo → Chatbot / Lambda. The notification path and any investigation Lambda now live in the management account |
| Management = tooling | `us-east-1` (linked) | Delegated administrator must be designated in this region too; findings **aggregate** to Tokyo | Same, per region | Global-service + `us-east-1` events | **Direct**: Health rule only → SNS us-east-1 |
| Members | each | Existing accounts must be enabled and subscribed to standards **manually per region** (local configuration auto-enables new accounts only) | Auto-enable `ALL` covers existing members. **Integration** → **delegation** | Event source | none |

Differences from case 1: no configuration policies (drift must be detected by hand), delegations are per region, SCPs do not protect the account that hosts the notification path. Health is the one service that gets simpler.

## Case 3 — Single member account (no delegation)

| Account | Region | Security Hub | GuardDuty / Inspector | AWS Health | Notification path |
|---|---|---|---|---|---|
| The account | `ap-northeast-1` (home) | FSBP enabled. Receives **aggregation** from linked regions. Evaluate global-resource controls (IAM.*) here only; disable them elsewhere | All protections. **Integration**; no native rule | **Direct** rule (both detail-types) | **Direct**: Security Hub rules (GuardDuty all severities, controls HIGH+) + Health rule → SNS Tokyo → Chatbot / Lambda. DLQ on every target |
| The account | `us-east-1` (linked) | Findings for CloudFront / IAM etc. **aggregate** to Tokyo; no rule | Foundational data sources only. **Integration** | **Direct** rule: global services + `us-east-1` + `us-west-2` backups | **Direct**: Health rule only → SNS us-east-1 → Chatbot / Lambda |
| The account | other regions (no workloads) | Link every region where GuardDuty runs (`ALL_REGIONS` once each has a module block; the example links three) so their findings are notified, and disable global-resource controls to remove duplicate findings; or disable Security Hub where unused | Keep detectors everywhere (unauthorized use is found wherever it happens), workload protections off. Inspector off | Rare; optionally one rule in `us-west-2` catches account-specific events from every region | none (optionally the `us-west-2` Health rule) |

Rule: the set of regions where GuardDuty is enabled must equal the set of linked regions, or findings in unlinked regions are never notified.

---

## Rules that apply to every case

1. **Notify once per failure episode.** Filter `Workflow.Status = NEW` / `RecordState = ACTIVE`; route the rule through a small Lambda that publishes to SNS and then sets `NOTIFIED` (a second independent target would not be ordered after the SNS delivery). Accepted risks go to `SUPPRESSED` in Security Hub, not into EventBridge patterns.
2. **Global-resource controls in one region only.** Disable IAM.* and similar controls outside the home region; otherwise each region reports the same account-level finding.
3. **Dead-letter queues on EventBridge targets.** Without one, an undeliverable event is dropped after the retry policy and only `FailedInvocations` remains.
4. **Least privilege for Chatbot.** Use the notification permissions from the Chatbot IAM guide, not `ReadOnlyAccess`, and set `guardrail_policy_arns` explicitly (the default is AdministratorAccess).
5. **SNS topics per rule region.** EventBridge publishes only to same-region topics. Subscribers (Chatbot, Lambda) may subscribe cross-region; a Lambda subscription's DLQ must be in the topic's region.
6. **Keep everything in Terraform**, including regions where services were enabled by hand; provider aliases per region, one module block per region.

---

## Terraform examples

`examples/security-notification-topology/` contains shared modules and one root per case (case 1 has two roots: `management/` and `security/`). All roots pass `terraform validate`; case 3 mirrors a production layout, cases 1 and 2 have not been applied against a real organization. The `securityhub-home` module includes the Lambda that marks findings `NOTIFIED`; global-resource controls are disabled outside the home region by `securityhub-region` (cases 2, 3) or by central configuration (case 1).

```bash
cd examples/security-notification-topology/case3-single-member
terraform init -backend=false
terraform validate
```

## References

- [Security Hub cross-Region aggregation](https://docs.aws.amazon.com/securityhub/latest/userguide/finding-aggregation.html) · [central configuration](https://docs.aws.amazon.com/securityhub/latest/userguide/central-configuration-intro.html) · [Organizations integration](https://docs.aws.amazon.com/securityhub/latest/userguide/designate-orgs-admin-account.html) · [EventBridge event types](https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-cwe-integration-types.html) · [workflow status](https://docs.aws.amazon.com/securityhub/latest/userguide/finding-workflow-status.html) · [service integrations](https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-internal-providers.html)
- [GuardDuty and Organizations](https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_organizations.html) · [GuardDuty → Security Hub](https://docs.aws.amazon.com/guardduty/latest/ug/securityhub-integration.html)
- [Inspector delegated administrator](https://docs.aws.amazon.com/inspector/latest/user/designating-admin.html)
- [AWS Health region coverage](https://docs.aws.amazon.com/health/latest/ug/choosing-a-region.html) · [event schema](https://docs.aws.amazon.com/health/latest/ug/aws-health-events-eventbridge-schema.html) · [organizational view](https://docs.aws.amazon.com/health/latest/ug/aggregating-health-events.html) · [enabling it](https://docs.aws.amazon.com/health/latest/ug/enable-organizational-view.html)
- [SNS cross-region delivery](https://docs.aws.amazon.com/sns/latest/dg/sns-cross-region-delivery.html) · [SNS dead-letter queues](https://docs.aws.amazon.com/sns/latest/dg/sns-dead-letter-queues.html)
- [Organizations management account best practices](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_best-practices_mgmt-acct.html) · [AWS SRA: Security Tooling account](https://docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/security-tooling.html)
