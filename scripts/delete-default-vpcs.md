# Delete Default VPCs

[日本語版はこちら](delete-default-vpcs.ja.md)

## Overview

A shell script that safely deletes unused Default VPCs across all AWS regions.

Default VPCs are automatically created in every region when an AWS account is provisioned. Since they are rarely used in production environments, removing them reduces the attack surface and satisfies security audit requirements (e.g., CIS AWS Foundations Benchmark).

## What it does

1. **Authentication check** — verifies AWS credentials and displays account/role info
2. **Default VPC detection** — uses the `is-default` filter per region
3. **Resource usage check** — queries 6 resource types (ENI, EC2, RDS, ELB, NAT Gateway, VPC Endpoint); if any exist, the region is skipped
4. **API error handling** — treats API failures as "check impossible" and skips deletion (never assumes 0 resources on error)
5. **IsDefault re-verification** — confirms `IsDefault=True` immediately before deletion
6. **Ordered deletion** — Subnets → Internet Gateway (detach + delete) → VPC
7. **Exit code** — returns non-zero if any region failed

## Prerequisites

- AWS CLI v2
- jq
- AWS credentials with EC2/RDS/ELB read and write permissions

## Usage

```bash
# Set credentials
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."  # if using temporary credentials

# Dry run (check only, no deletions)
./scripts/delete-default-vpcs.sh

# Execute deletions
./scripts/delete-default-vpcs.sh --execute
```

## Safety design

| Concern | Mitigation |
|---|---|
| Accidentally deleting a non-default VPC | Only targets VPCs with `is-default=true`; re-verifies `IsDefault` before deletion |
| Deleting a VPC with active resources | 6-resource pre-check; ENI count alone catches most hidden dependencies |
| API errors silently treated as "no resources" | API failures return `-1`, causing the region to be skipped |
| Partial deletion leaves broken state | Each step checks for errors; on failure, the region is skipped and counted |
| Running destructive operations by mistake | Default mode is dry-run; `--execute` flag required |
