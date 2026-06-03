# Terraform モジュール規約

プロジェクト間で Terraform モジュールの構成と変数の使い方を一貫させるための規約です。

> AWS リソース名および Terraform 識別子の命名規則については [naming-conventions.ja.md](naming-conventions.ja.md) を参照してください。

## モジュール構成

各モジュールは以下のファイルで構成する。

| ファイル | 内容 |
|---|---|
| `variables.tf` | 入力変数 |
| `main.tf` | リソース定義、`locals` ブロック |
| `outputs.tf` | 出力値 |

`locals` ブロックは `main.tf` の先頭に記述する。モジュールが大規模化した場合は `locals.tf` に分離する。内容が無いファイルは作成しなくてよい。

## 変数の使い分け

- 環境（`environment`）、サービス名（`service_name`）、インフラ設定（CIDR、ARN 等）は `variable` で外部から注入する
- 命名規則に従うリソース名は `locals` で構築する（`variable` にしない）

```hcl
variable "service_name" {}
variable "environment"  {}

locals {
  name_prefix = "${var.service_name}-${var.environment}"
}
```
