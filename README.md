# terraform-aws-recipes

A collection of Terraform recipes for AWS environments.

[日本語版はこちら](README.ja.md)

## Recipes

| Recipe | Category | Description |
|---|---|---|
| [GuardDuty Multi-Region Management](guardduty-multiregion-setup.md) | Security | Enable GuardDuty across all regions, managed from a single Terraform workspace. Includes Slack notifications via AWS Chatbot for MEDIUM+ findings. |
| [SecurityHub Finding Aggregator](securityhub-finding-aggregator.md) | Security | Simplify GuardDuty notification pipeline using SecurityHub cross-region finding aggregation. Alternative to per-region EventBridge forwarding — eliminates all per-region notification resources. |
| [AWS Health Notification via EventBridge](health-notification-via-eventbridge.md) | Operations | Capture all AWS Health events from all regions with a single EventBridge rule in us-west-2 (Nov 2025 feature). AI-powered analysis with severity-based digest batching. |

## Scripts

| Script | Category | Description |
|---|---|---|
| [Delete Default VPCs](scripts/delete-default-vpcs.md) | Security | Safely delete unused Default VPCs across all AWS regions with dry-run support and multi-layer safety checks. |

## Usage

Each recipe is designed as a construction prompt for AI assistants. Fill in the prerequisite parameters and pass it as a prompt to generate Terraform code.

## License

MIT
