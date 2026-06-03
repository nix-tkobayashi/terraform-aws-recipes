# Terraform AWS Naming Conventions

Guidelines for naming AWS resources and Terraform identifiers consistently across projects.

> For Terraform module structure and variable conventions, see [terraform-conventions.md](terraform-conventions.md).

## Placeholder Reference

| Placeholder | Terraform variable | Example value |
|---|---|---|
| `{service_name}` | `var.service_name` | `my-service` |
| `{env}` | `var.environment` | `test`, `prod` |
| `{resource}` | — (literal suffix) | `alb`, `ecs-sg`, `codebuild` |
| `{function}` | — (workload unit name) | `web`, `worker` |
| `{account_id}` | `data.aws_caller_identity.current.account_id` | `123456789012` |

---

## AWS Resource Names

### Basic Pattern

```
{service_name}-{env}-{resource}
```

Examples: `my-service-test-alb`, `my-service-prod-ecs-sg`

### Workload-Specific Resources

To distinguish multiple workloads within the same cluster or service group, append a `{function}` suffix. The `{function}` token identifies the workload unit (e.g. `web`, `worker`, `batch`) — not a traffic-routing term like `blue`/`green`.

```
{service_name}-{env}-{resource}-{function}
```

Example: `my-service-test-ecs-service-web`

This pattern applies to any workload type: ECS services, Lambda functions, EKS deployments, etc.

### Globally Unique Resources (e.g. S3 Buckets)

Append the AWS account ID to ensure global uniqueness.

```
{service_name}-{env}-{resource}-{account_id}
```

Example: `my-service-prod-artifacts-123456789012`

### ALB Target Groups

AWS limits Target Group names to **32 characters**. Use `-tg-{function}` as the suffix.

Example: `my-service-prod-tg-web` (22 characters)

### Region in Resource Names

For single-region deployments, do **not** include the region in resource names.  
If multi-region support is needed in the future, adopt `{service_name}-{env}-{region}-{resource}`.

---

## Terraform Resource Identifiers

- Hyphen-separated context (AWS resource names, variable defaults): `my-service`
- Underscore-separated context (`resource`/`data` block labels, variable names): `my_service`

### Resource Block Label Convention

The second argument (label) of `resource` / `data` blocks **must not repeat the resource type**.  
When you write `resource "aws_ecs_service"`, the fact that it is an ECS service is already self-evident.

Labels should reflect the resource's responsibility:

```
{service}_{function}   # Resources scoped per workload (when multiple exist)
{service}              # Resources that are unique within the module scope
{purpose}              # Shared infrastructure resources (IAM, S3, pipelines, etc.)
```

| Pattern | Target resources | Example |
|---|---|---|
| `{service}_{function}` | ECS service/task definition, ALB TG/listener rule, etc. | `my_service_web` |
| `{service}` | ECS cluster, ALB, etc. (one per module scope) | `my_service` |
| `{purpose}` | IAM role/policy, S3 bucket, CodePipeline, etc. | `codepipeline`, `ecs_tasks`, `codepipeline_artifact` |

**Bad examples:**

```hcl
# Resource type duplicated in the label
resource "aws_ecs_service" "my_service_ecs_service_web" { ... }
```

**Good examples:**

```hcl
resource "aws_ecs_cluster"      "my_service"            { ... }
resource "aws_ecs_service"      "my_service_web"        { ... }
resource "aws_lb_target_group"  "my_service_web"        { ... }
resource "aws_iam_role"         "ecs_tasks"             { ... }
resource "aws_s3_bucket"        "codepipeline_artifact" { ... }
data     "aws_iam_policy_document" "ecs_tasks"          { ... }
```

### Special Cases

**Generic data sources**

For environment references such as `aws_caller_identity`, `aws_region`, and `aws_partition`, follow Terraform convention and use `current`.

```hcl
data "aws_caller_identity" "current" {}
data "aws_region"          "current" {}
```

**Child resources attached to a parent**

For resources that accompany a parent 1-to-1 (e.g. ALB listener, SNS topic policy), use the protocol name or the parent's `{purpose}` as the label.

```hcl
resource "aws_lb_listener"      "public_http"     { ... }  # HTTP → HTTPS redirect
resource "aws_lb_listener"      "public_https"    { ... }  # Main HTTPS listener
resource "aws_sns_topic_policy" "pipeline_notify" { ... }
```

**Multiple resources for the same workload**

When `{service}_{function}` alone cannot distinguish multiple resources for the same workload, use `{function}_{purpose}`.

```hcl
resource "aws_appautoscaling_target"   "web_request_count"           { ... }
resource "aws_appautoscaling_policy"   "web_request_count_scale_out" { ... }
resource "aws_appautoscaling_policy"   "web_request_count_scale_in"  { ... }
resource "aws_cloudwatch_metric_alarm" "web_request_count_high"      { ... }
resource "aws_cloudwatch_metric_alarm" "web_request_count_low"       { ... }
```

**IAM role and its associated policy/policy document**

The same `{purpose}` label may be shared across multiple resource types (`aws_iam_role`, `aws_iam_role_policy`, `aws_iam_policy_document`) because the type is already self-evident from the resource kind.

```hcl
resource "aws_iam_role"        "ecs_tasks" { ... }
resource "aws_iam_role_policy" "ecs_tasks" { ... }
data "aws_iam_policy_document" "ecs_tasks" { ... }
```

Add a qualifier (e.g. `_assume_role`) only when readability suffers within the same module.

---

## `name_prefix` Pattern

Define `name_prefix` in `locals` within each module and environment layer, and use it to construct all resource names.

```hcl
locals {
  name_prefix = "${var.service_name}-${var.environment}"
}

resource "aws_ecs_cluster" "my_service" {
  name = local.name_prefix
}

resource "aws_ecs_service" "my_service_web" {
  name = "${local.name_prefix}-web"
}
```
