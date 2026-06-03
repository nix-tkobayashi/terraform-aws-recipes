# Terraform AWS 命名規則

プロジェクト間で AWS リソースと Terraform 識別子を一貫して命名するためのガイドラインです。

> Terraform のモジュール構成・変数の使い分けについては [terraform-conventions.ja.md](terraform-conventions.ja.md) を参照してください。

## プレースホルダ対応表

| プレースホルダ | Terraform 変数 | 値の例 |
|---|---|---|
| `{service_name}` | `var.service_name` | `my-service` |
| `{env}` | `var.environment` | `test`, `prod` |
| `{resource}` | —（リテラルのサフィックス）| `alb`, `ecs-sg`, `codebuild` |
| `{function}` | —（ワークロード単位の名前）| `web`, `worker` |
| `{account_id}` | `data.aws_caller_identity.current.account_id` | `123456789012` |

---

## AWS リソース名

### 基本パターン

```
{service_name}-{env}-{resource}
```

例: `my-service-test-alb`, `my-service-prod-ecs-sg`

### ワークロード固有のリソース

同一クラスタやサービスグループ内で複数のワークロードを区別するため、末尾に `{function}` サフィックスを付与する。`{function}` はワークロード単位の名前（例: `web`, `worker`, `batch`）を指し、トラフィック経路や色名（`blue`/`green`）とは混在させない。

```
{service_name}-{env}-{resource}-{function}
```

例: `my-service-test-ecs-service-web`

このパターンは ECS サービスに限らず、Lambda 関数や EKS デプロイメントなど任意のワークロードタイプに適用できる。

### グローバルに一意が必要なリソース（S3 バケット等）

末尾に AWS アカウント ID を付与してグローバルな一意性を確保する。

```
{service_name}-{env}-{resource}-{account_id}
```

例: `my-service-prod-artifacts-123456789012`

### ALB Target Group

AWS の制約により Target Group 名は **32文字以内**。サフィックスは `-tg-{function}` で固定する。

例: `my-service-prod-tg-web`（22文字）

### リソース名へのリージョン含有

単一リージョン運用の場合、リソース名にリージョンは**含めない**。  
将来マルチリージョン構成に移行する場合は `{service_name}-{env}-{region}-{resource}` に変更する。

---

## Terraform リソース識別子

- ハイフン区切りの文脈（AWS リソース名、変数デフォルト値）: `my-service`
- アンダースコア区切りの文脈（`resource`/`data` ブロック名、変数名）: `my_service`

### リソースブロック識別子の命名規則

`resource` / `data` ブロックの第2引数（識別子）は、**リソース種別を含めない**。  
`resource "aws_ecs_service"` と書いた時点で ECS サービスであることは自明なため。

識別子はリソースの責務で命名する。

```
{service}_{function}   # ワークロード単位のリソース（同種が複数存在する場合）
{service}              # モジュールスコープ上1つに限定されるリソース
{purpose}              # 共通インフラリソース（IAM, S3, パイプライン等）
```

| パターン | 対象リソース | 例 |
|---|---|---|
| `{service}_{function}` | ECS サービス/タスク定義、ALB TG・ルール等 | `my_service_web` |
| `{service}` | ECS クラスター、ALB 等（スコープ上1つ） | `my_service` |
| `{purpose}` | IAM ロール/ポリシー、S3 バケット、CodePipeline 等 | `codepipeline`, `ecs_tasks`, `codepipeline_artifact` |

**NG 例:**

```hcl
# リソース種別の重複
resource "aws_ecs_service" "my_service_ecs_service_web" { ... }
```

**OK 例:**

```hcl
resource "aws_ecs_cluster"      "my_service"            { ... }
resource "aws_ecs_service"      "my_service_web"        { ... }
resource "aws_lb_target_group"  "my_service_web"        { ... }
resource "aws_iam_role"         "ecs_tasks"             { ... }
resource "aws_s3_bucket"        "codepipeline_artifact" { ... }
data     "aws_iam_policy_document" "ecs_tasks"          { ... }
```

### 補足: ルールが直接当てはまらないケース

**汎用 data source**

`aws_caller_identity` / `aws_region` / `aws_partition` のような環境参照は、Terraform の慣習に従い `current` を使う。

```hcl
data "aws_caller_identity" "current" {}
data "aws_region"          "current" {}
```

**親リソースにぶら下がる子リソース**

ALB listener や SNS topic policy のような「親リソースに1対1で付随する設定リソース」は、プロトコル名や親の `{purpose}` を識別子に使う。

```hcl
resource "aws_lb_listener"      "public_http"     { ... }  # HTTP → HTTPS リダイレクト
resource "aws_lb_listener"      "public_https"    { ... }  # メイン HTTPS リスナー
resource "aws_sns_topic_policy" "pipeline_notify" { ... }
```

**同一ワークロードに複数のリソースが存在する場合**

`{service}_{function}` だけでは同一ワークロードの複数リソースを区別できない場合は `{function}_{purpose}` パターンを使う。

```hcl
resource "aws_appautoscaling_target"   "web_request_count"           { ... }
resource "aws_appautoscaling_policy"   "web_request_count_scale_out" { ... }
resource "aws_appautoscaling_policy"   "web_request_count_scale_in"  { ... }
resource "aws_cloudwatch_metric_alarm" "web_request_count_high"      { ... }
resource "aws_cloudwatch_metric_alarm" "web_request_count_low"       { ... }
```

**IAM ロールと同名の policy / policy document**

同一の `{purpose}` を複数のリソース種別（`aws_iam_role` / `aws_iam_role_policy` / `aws_iam_policy_document`）で共有してよい。種別が識別子から自明なため。

```hcl
resource "aws_iam_role"        "ecs_tasks" { ... }
resource "aws_iam_role_policy" "ecs_tasks" { ... }
data "aws_iam_policy_document" "ecs_tasks" { ... }
```

同一モジュール内で可読性が落ちる場合は `_assume_role` 等の補助語を追加する。

---

## `name_prefix` パターン

各モジュール及び環境定義層では `locals` に `name_prefix` を定義し、すべてのリソース名の構築に使用する。

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
