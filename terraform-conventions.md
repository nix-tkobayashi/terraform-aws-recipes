# Terraform Module Conventions

Conventions for structuring Terraform modules and managing variables consistently across projects.

> For AWS resource and Terraform identifier naming rules, see [naming-conventions.md](naming-conventions.md).

## Module Structure

Each module should consist of the following files:

| File | Content |
|---|---|
| `variables.tf` | Input variables |
| `main.tf` | Resource definitions and `locals` block |
| `outputs.tf` | Output values |

Place the `locals` block at the top of `main.tf`. If the module grows large, move it to a separate `locals.tf`. Omit files that would be empty.

## Variable Usage

- Inject environment (`environment`), service name (`service_name`), and infrastructure settings (CIDR, ARN, etc.) via `variable`
- Build resource names that follow naming conventions in `locals` — do not expose them as `variable`

```hcl
variable "service_name" {}
variable "environment"  {}

locals {
  name_prefix = "${var.service_name}-${var.environment}"
}
```
