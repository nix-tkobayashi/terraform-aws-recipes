# GuardDuty 全リージョン一元管理 — Terraform 構築プロンプト

[English version](guardduty-multiregion-setup.md)

## 概要

AWS Organizations 環境において、GuardDuty を対象リージョンで有効化し、単一の Terraform ワークスペース（management 環境）から一元管理する構成を構築してください。MEDIUM 以上の Finding は集約リージョンに集約し、AWS Chatbot 経由で Slack に通知します。

### 用語定義

| 用語 | 意味 |
|---|---|
| **management account** | AWS Organizations の管理アカウント。組織の作成者であり、委任管理者の指定権限を持つ |
| **delegated administrator** | GuardDuty の委任管理者アカウント。Detector・メンバー管理・Organization 設定を行う |
| **集約リージョン** | EventBridge / SNS による通知を集約するリージョン |

> **本仕様の前提**: management account が GuardDuty の delegated administrator を兼任する構成です。delegated administrator を別アカウントにする場合は、management account 用の provider と delegated admin 用の provider（assume_role）を分離する設計が別途必要になります。

---

## 前提条件

以下の情報を事前に確認・提供してください：

| 項目 | 説明 |
|---|---|
| **management account ID** | AWS Organizations の management account ID |
| **delegated admin account ID** | GuardDuty の delegated administrator（本仕様では management account と同一） |
| **メンバーアカウント一覧** | `{ "アカウントID" = "rootメールアドレス" }` の map 形式 |
| **対象リージョン一覧** | GuardDuty を有効化するリージョン（後述のサンプルを参考にプロジェクトごとに定義） |
| **集約リージョン** | EventBridge / SNS 通知を集約するリージョン（例: `ap-northeast-1`） |
| **Slack workspace ID** | AWS Chatbot と連携する Slack ワークスペース ID |
| **Slack channel ID** | GuardDuty Finding の通知先 Slack チャンネル ID |
| **Terraform backend** | S3 バケット名、key、リージョン |
| **既存 Detector ID** | 各リージョンで既に GuardDuty が有効な場合、その Detector ID（`aws guardduty list-detectors --region <region>` で取得） |

### 事前準備

- AWS Chatbot コンソールで Slack ワークスペースとの連携を設定しておくこと（Terraform では Slack workspace の連携自体は管理できない）

### コスト確認

GuardDuty を全リージョン・全アカウントで有効化すると、EBS Malware Protection・Runtime Monitoring 等の保護機能により課金が発生します。apply 前に AWS の料金ページで費用影響を確認してください。

---

## ディレクトリ構成

```
terraform/
├── env/management/                             # 単一 tfstate で全リージョン管理
│   ├── backend.tf                              # provider alias + S3 backend
│   ├── locals.tf                               # project / environment / account ID / regions
│   ├── guardduty.tf                            # module 呼出 + outputs
│   ├── chatbot.tf                              # AWS Chatbot Slack 連携
│
└── modules/management/guardduty-region/         # 1 リージョン分の GuardDuty 設定 + 通知集約
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    └── versions.tf
```

---

## 構築手順

### Step 1: modules/management/guardduty-region/ — 共通モジュール

1 リージョン分の GuardDuty 設定をモジュール化します。このモジュールに通知集約（SNS・EventBridge）とクロスリージョン転送の機能も含め、`is_aggregation_region` / `enable_finding_forwarding` 変数で制御します。

#### variables.tf

```hcl
variable "delegated_admin_account_id" {
  description = "GuardDuty delegated administrator として設定する AWS アカウント ID"
  type        = string
}

variable "member_accounts" {
  description = "GuardDuty メンバーアカウント (key: account_id, value: root email)"
  type        = map(string)
  default     = {}
}

variable "is_aggregation_region" {
  description = "通知集約リージョンかどうか。true にすると SNS Topic、Custom EventBus、EventBridge ルールを作成する"
  type        = bool
  default     = false
}

variable "management_account_id" {
  description = "management account の AWS アカウント ID。is_aggregation_region = true の場合に必要"
  type        = string
  default     = ""
}

variable "enable_finding_forwarding" {
  description = "集約リージョンへの EventBridge 転送ルールを作成するかどうか。集約リージョン以外で true にする"
  type        = bool
  default     = false
}

variable "forwarding_event_bus_arn" {
  description = "集約リージョンの Custom Event Bus ARN。enable_finding_forwarding = true の場合に必要"
  type        = string
  default     = ""
}

variable "forwarding_role_arn" {
  description = "クロスリージョン EventBridge 転送用 IAM Role ARN。enable_finding_forwarding = true の場合に必要"
  type        = string
  default     = ""
}
```

#### main.tf

以下のリソースを含めてください：

```hcl
# --- Detector ---
resource "aws_guardduty_detector" "this" {
  enable                       = true
  finding_publishing_frequency = "SIX_HOURS"
}

# --- Detector Features (delegated admin アカウント自身の保護) ---
# 以下の機能を個別に aws_guardduty_detector_feature で定義:
#   S3_DATA_EVENTS          → ENABLED
#   EKS_AUDIT_LOGS          → ENABLED
#   EBS_MALWARE_PROTECTION  → ENABLED
#   RDS_LOGIN_EVENTS        → ENABLED
#   LAMBDA_NETWORK_LOGS     → ENABLED
#   EKS_RUNTIME_MONITORING  → DISABLED (additional: EKS_ADDON_MANAGEMENT=DISABLED)
#   RUNTIME_MONITORING      → ENABLED
#     additional: EKS_ADDON_MANAGEMENT=DISABLED
#     additional: ECS_FARGATE_AGENT_MANAGEMENT=ENABLED
#     additional: EC2_AGENT_MANAGEMENT=DISABLED

# --- メンバーアカウント登録 ---
resource "aws_guardduty_member" "this" {
  for_each = var.member_accounts

  detector_id                = aws_guardduty_detector.this.id
  account_id                 = each.key
  email                      = each.value
  invite                     = false
  disable_email_notification = true

  lifecycle {
    # Organizations 管理下では AWS が invite/disassociate を制御するため
    # これらのフィールドの diff を無視する（ignore しないと毎回差分が出る）
    ignore_changes = [email, disable_email_notification, invite]
  }
}

# --- Organizations 委任管理者 ---
resource "aws_guardduty_organization_admin_account" "this" {
  admin_account_id = var.delegated_admin_account_id
}

# --- Organizations 自動有効化 ---
resource "aws_guardduty_organization_configuration" "this" {
  auto_enable_organization_members = "ALL"
  detector_id                      = aws_guardduty_detector.this.id
  depends_on                       = [aws_guardduty_organization_admin_account.this]
}

# --- Organizations Feature ポリシー ---
# 以下を aws_guardduty_organization_configuration_feature で定義:
#   S3_DATA_EVENTS          → auto_enable = "ALL"
#   EBS_MALWARE_PROTECTION  → auto_enable = "ALL"
#   RDS_LOGIN_EVENTS        → auto_enable = "ALL"
#   LAMBDA_NETWORK_LOGS     → auto_enable = "NONE"
#   EKS_AUDIT_LOGS          → auto_enable = "NONE"
#   EKS_RUNTIME_MONITORING  → auto_enable = "NONE"
#   RUNTIME_MONITORING      → auto_enable = "ALL"
#     additional: ECS_FARGATE_AGENT_MANAGEMENT = "ALL"
#     additional: EC2_AGENT_MANAGEMENT = "NONE"
#     additional: EKS_ADDON_MANAGEMENT = "NONE"

# =============================================================================
# 通知集約（集約リージョンのみ）
# =============================================================================

# --- SNS Topic ---
resource "aws_sns_topic" "guardduty_findings" {
  count = var.is_aggregation_region ? 1 : 0
  name  = "guardduty-findings"
}

resource "aws_sns_topic_policy" "guardduty_findings" {
  count = var.is_aggregation_region ? 1 : 0
  arn   = aws_sns_topic.guardduty_findings[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.guardduty_findings[0].arn
      }
    ]
  })
}

# --- Custom Event Bus ---
resource "aws_cloudwatch_event_bus" "guardduty_findings" {
  count = var.is_aggregation_region ? 1 : 0
  name  = "guardduty-findings"
}

resource "aws_cloudwatch_event_bus_policy" "guardduty_findings" {
  count          = var.is_aggregation_region ? 1 : 0
  event_bus_name = aws_cloudwatch_event_bus.guardduty_findings[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowSameAccountPutEvents"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.management_account_id}:root" }
        Action    = "events:PutEvents"
        Resource  = aws_cloudwatch_event_bus.guardduty_findings[0].arn
      }
    ]
  })
}

# --- EventBridge Rule: default bus → SNS ---
resource "aws_cloudwatch_event_rule" "guardduty_default_bus" {
  count       = var.is_aggregation_region ? 1 : 0
  name        = "guardduty-findings-to-sns"
  description = "Forward GuardDuty MEDIUM+ findings to SNS"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 4] }]
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_default_bus_to_sns" {
  count     = var.is_aggregation_region ? 1 : 0
  rule      = aws_cloudwatch_event_rule.guardduty_default_bus[0].name
  target_id = "guardduty-sns"
  arn       = aws_sns_topic.guardduty_findings[0].arn

  input_transformer {
    input_paths = {
      account     = "$.account"
      region      = "$.region"
      id          = "$.detail.id"
      severity    = "$.detail.severity"
      type        = "$.detail.type"
      title       = "$.detail.title"
      description = "$.detail.description"
    }
    input_template = "\"[GuardDuty] <title>\\n\\nAccount:  <account>\\nRegion:   <region>\\nSeverity: <severity>\\nType:     <type>\\n\\n<description>\\n\\nhttps://console.aws.amazon.com/guardduty/home?region=<region>#/findings?search=id%3D<id>\""
  }
}

# --- EventBridge Rule: custom bus → SNS ---
resource "aws_cloudwatch_event_rule" "guardduty_custom_bus" {
  count          = var.is_aggregation_region ? 1 : 0
  name           = "guardduty-findings-custom-to-sns"
  description    = "Forward findings from custom bus to SNS"
  event_bus_name = aws_cloudwatch_event_bus.guardduty_findings[0].name

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 4] }]
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_custom_bus_to_sns" {
  count          = var.is_aggregation_region ? 1 : 0
  rule           = aws_cloudwatch_event_rule.guardduty_custom_bus[0].name
  event_bus_name = aws_cloudwatch_event_bus.guardduty_findings[0].name
  target_id      = "guardduty-sns"
  arn            = aws_sns_topic.guardduty_findings[0].arn

  input_transformer {
    input_paths = {
      account     = "$.account"
      region      = "$.region"
      id          = "$.detail.id"
      severity    = "$.detail.severity"
      type        = "$.detail.type"
      title       = "$.detail.title"
      description = "$.detail.description"
    }
    input_template = "\"[GuardDuty] <title>\\n\\nAccount:  <account>\\nRegion:   <region>\\nSeverity: <severity>\\nType:     <type>\\n\\n<description>\\n\\nhttps://console.aws.amazon.com/guardduty/home?region=<region>#/findings?search=id%3D<id>\""
  }
}

# --- IAM Role for cross-region forwarding ---
resource "aws_iam_role" "guardduty_eventbridge_forwarding" {
  count = var.is_aggregation_region ? 1 : 0
  name  = "guardduty-eventbridge-forwarding"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "guardduty_eventbridge_forwarding" {
  count = var.is_aggregation_region ? 1 : 0
  name  = "guardduty-eventbridge-forwarding"
  role  = aws_iam_role.guardduty_eventbridge_forwarding[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "events:PutEvents"
        Resource = aws_cloudwatch_event_bus.guardduty_findings[0].arn
      }
    ]
  })
}

# =============================================================================
# クロスリージョン転送（集約リージョン以外）
# =============================================================================

resource "aws_cloudwatch_event_rule" "guardduty_forward" {
  count       = var.enable_finding_forwarding ? 1 : 0
  name        = "guardduty-findings-forward"
  description = "Forward GuardDuty MEDIUM+ findings to aggregation region"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 4] }]
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_forward" {
  count     = var.enable_finding_forwarding ? 1 : 0
  rule      = aws_cloudwatch_event_rule.guardduty_forward[0].name
  target_id = "guardduty-forward"
  arn       = var.forwarding_event_bus_arn
  role_arn  = var.forwarding_role_arn
}
```

#### outputs.tf

```hcl
output "detector_id" {
  description = "GuardDuty Detector ID"
  value       = aws_guardduty_detector.this.id
}

output "sns_topic_arn" {
  description = "GuardDuty findings SNS Topic ARN (集約リージョンのみ)"
  value       = var.is_aggregation_region ? aws_sns_topic.guardduty_findings[0].arn : ""
}

output "event_bus_arn" {
  description = "クロスリージョン転送用 Custom Event Bus ARN (集約リージョンのみ)"
  value       = var.is_aggregation_region ? aws_cloudwatch_event_bus.guardduty_findings[0].arn : ""
}

output "forwarding_role_arn" {
  description = "クロスリージョン EventBridge 転送用 IAM Role ARN (集約リージョンのみ)"
  value       = var.is_aggregation_region ? aws_iam_role.guardduty_eventbridge_forwarding[0].arn : ""
}
```

#### versions.tf

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}
```

---

### Step 2: env/management/backend.tf — Provider Alias

対象リージョンに対して provider alias を定義します。

```hcl
terraform {
  backend "s3" {
    bucket = "<S3バケット名>"
    key    = "management/terraform.tfstate"
    region = "<集約リージョン>"
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "<バージョン>" }
  }
}

# デフォルト provider (集約リージョン)
provider "aws" {
  region = "<集約リージョン>"
  default_tags {
    tags = {
      Project     = local.project
      Environment = local.environment
      ManagedBy   = "Terraform"
    }
  }
}

# 対象リージョンごとに alias を定義（集約リージョン以外）:
# 形式:
#   provider "aws" {
#     alias  = "us_east_1"
#     region = "us-east-1"
#     default_tags { tags = { Project = local.project, Environment = local.environment, ManagedBy = "Terraform" } }
#   }
```

---

### Step 3: env/management/locals.tf — 共通変数

プロジェクト情報とアカウント情報を `locals.tf` にまとめます。

```hcl
locals {
  project     = "<プロジェクト名>"
  environment = "management"

  management_account_id      = "<management account ID>"
  delegated_admin_account_id = "<delegated admin アカウント ID>"

  member_accounts = {
    "<アカウントID>" = "<rootメール>"
    # ... 全メンバー分
  }

  aggregation_region = "<集約リージョン>"

  # 既存 Detector ID（既に GuardDuty が有効なリージョンのみ必要）
  detector_ids = {
    ap_northeast_1 = "<detector_id>"
    us_east_1      = "<detector_id>"
    # ... 各リージョン分
  }
}
```

---

### Step 4: env/management/guardduty.tf — モジュール呼び出し

#### import ブロック（既存リソースの取り込み）

既に AWS 上で GuardDuty が有効なリージョンについて、以下の import を定義します。

**基本リソース**（各リージョンにつき 3 つ）:

```hcl
import {
  to = module.guardduty_<region>.aws_guardduty_detector.this
  id = local.detector_ids.<region>
}
import {
  to = module.guardduty_<region>.aws_guardduty_organization_admin_account.this
  id = local.delegated_admin_account_id
}
import {
  to = module.guardduty_<region>.aws_guardduty_organization_configuration.this
  id = local.detector_ids.<region>
}
```

**メンバーアカウント**（既に登録済みの場合）:

```hcl
import {
  to = module.guardduty_<region>.aws_guardduty_member.this["<account_id>"]
  id = "${local.detector_ids.<region>}:<account_id>"
}
```

**Feature リソース**（既存の Detector Feature / Organization Configuration Feature がある場合）:

```hcl
# aws_guardduty_detector_feature は import 不要（Terraform が差分で管理する）
# aws_guardduty_organization_configuration_feature も同様
# ただし、既存設定との差分が大きい場合は plan で変更内容をよく確認すること
```

> **補足**: `detector_feature` / `organization_configuration_feature` は Terraform が Detector ID を基に自動的に差分管理するため、通常は import 不要です。ただし plan 時に意図しない変更が出ないか必ず確認してください。

#### moved ブロック（既存フラットリソースからモジュールへの移行時のみ）

既に Terraform state にフラットなリソース（`aws_guardduty_detector.ap_northeast_1` など）がある場合、`moved` ブロックで state を壊さず移行します：

```hcl
moved {
  from = aws_guardduty_detector.<region>
  to   = module.guardduty_<region>.aws_guardduty_detector.this
}
```

**注意**: import と moved は排他的。同じリソースに両方使わないこと。

#### モジュール呼び出し

集約リージョンは `is_aggregation_region = true` と `management_account_id` を渡します。他リージョンは `enable_finding_forwarding = true` と集約リージョンモジュールの出力（`event_bus_arn` / `forwarding_role_arn`）を渡します。

```hcl
# 集約リージョン
module "guardduty_<aggregation_region>" {
  source                     = "../../modules/management/guardduty-region"
  delegated_admin_account_id = local.delegated_admin_account_id
  member_accounts            = local.member_accounts
  is_aggregation_region      = true
  management_account_id      = local.management_account_id
  providers                  = { aws = aws }  # デフォルト provider（集約リージョン）
}

# 他リージョン（集約リージョン以外）
module "guardduty_<other_region>" {
  source                     = "../../modules/management/guardduty-region"
  delegated_admin_account_id = local.delegated_admin_account_id
  member_accounts            = local.member_accounts
  enable_finding_forwarding  = true
  forwarding_event_bus_arn   = module.guardduty_<aggregation_region>.event_bus_arn
  forwarding_role_arn        = module.guardduty_<aggregation_region>.forwarding_role_arn
  providers                  = { aws = aws.<other_region> }
}

# ... 対象リージョンすべてについて同様
```

#### outputs

各リージョンの Detector ID と集約リージョンの SNS Topic ARN を出力：

```hcl
output "guardduty_detector_id_<region>" {
  description = "GuardDuty Detector ID (<region>)"
  value       = module.guardduty_<region>.detector_id
}

output "guardduty_sns_topic_arn" {
  description = "GuardDuty findings SNS Topic ARN (<aggregation_region>)"
  value       = module.guardduty_<aggregation_region>.sns_topic_arn
}
```

---

### Step 5: env/management/chatbot.tf — Slack 通知（AWS Chatbot）

SNS Topic を AWS Chatbot に接続し、GuardDuty Finding を Slack に通知します。

> **事前準備**: AWS Chatbot コンソールで Slack ワークスペースとの連携を完了させておく必要があります。Terraform では workspace の連携自体は管理できません。

```hcl
# --- IAM Role for AWS Chatbot ---
resource "aws_iam_role" "chatbot_guardduty" {
  name = "chatbot-guardduty-findings"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "chatbot.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "chatbot_guardduty" {
  role       = aws_iam_role.chatbot_guardduty.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# --- AWS Chatbot Slack Channel Configuration ---
resource "aws_chatbot_slack_channel_configuration" "guardduty" {
  configuration_name = "guardduty-findings"
  iam_role_arn       = aws_iam_role.chatbot_guardduty.arn
  slack_channel_id   = "<Slack チャンネル ID>"
  slack_team_id      = "<Slack ワークスペース ID>"
  sns_topic_arns     = [module.guardduty_<aggregation_region>.sns_topic_arn]
  logging_level      = "ERROR"
}
```

#### アーキテクチャ

```
[集約リージョン]
  default EventBus → EventBridge Rule → SNS Topic ─┐
  custom  EventBus → EventBridge Rule → SNS Topic ──┤
                                                     └→ AWS Chatbot → Slack

[他リージョン]
  default EventBus → EventBridge Rule → 集約リージョンの custom EventBus に転送
```

---

## 注意事項・Tips

### AWS の挙動に関する注意

1. **`aws_guardduty_member` の lifecycle ignore_changes は必須**
   - Organizations 管理下のメンバーは AWS 側が invite/email を制御するため、`ignore_changes = [email, disable_email_notification, invite]` を入れないと毎回差分が出る

2. **`aws_guardduty_organization_admin_account` は management account の権限で実行が必要**
   - delegated admin アカウントの credentials ではなく、Organizations の management account から apply すること

3. **import ブロックは plan/apply 1 回目で消化される**
   - 初回 apply 後に import ブロックを削除しても OK（残しておいても害はない）

4. **Detector は各リージョンに 1 つしか存在できない**
   - 既に有効な場合は import で取り込む。新規作成しようとするとエラーになる

5. **EKS_RUNTIME_MONITORING と RUNTIME_MONITORING は排他的な関係**
   - RUNTIME_MONITORING が後継。EKS_RUNTIME_MONITORING は DISABLED にして RUNTIME_MONITORING 側の EKS_ADDON_MANAGEMENT で制御する

6. **AWS Chatbot の Slack ワークスペース連携は手動設定が必要**
   - Terraform では `aws_chatbot_slack_channel_configuration` でチャンネル設定を管理できるが、ワークスペース自体の連携は AWS Chatbot コンソールから事前に行う必要がある

7. **`management_account_id` と `delegated_admin_account_id` は同一前提**
   - 本仕様では management account が delegated administrator を兼任する構成のため、両者は同じ値になる。EventBridge bus policy は `management_account_id` を参照するため、値がずれるとクロスリージョン転送が壊れる点に注意

### Terraform 実装の注意

1. **`for_each` での全リージョン展開は使えない**
   - provider alias は `for_each` / `count` に渡せないため、対象リージョン数だけモジュール呼び出しを明示的に書く必要がある

2. **moved と import は排他的**
   - 既に Terraform state にあるリソースは `moved` で移行、state にないが AWS 上に存在するリソースは `import` で取り込む

3. **apply 順序**
   - 初回は `terraform plan` で import/moved の結果を確認してから apply
   - 大量のリソース（リージョン数 × リソース数）になるため plan 結果をよく確認すること

---

## 対象リージョンについて

対象リージョンはプロジェクトごとに定義してください。以下のコマンドで ENABLED_BY_DEFAULT リージョンを確認できます：

```bash
aws account list-regions --region-opt-status-contains ENABLED_BY_DEFAULT \
  --query 'Regions[].RegionName' --output text
```

### サンプル: 17 ENABLED_BY_DEFAULT リージョン

```
ap-northeast-1, ap-northeast-2, ap-northeast-3,
ap-south-1, ap-southeast-1, ap-southeast-2,
ca-central-1,
eu-central-1, eu-north-1, eu-west-1, eu-west-2, eu-west-3,
sa-east-1,
us-east-1, us-east-2, us-west-1, us-west-2
```

> **注意**: GuardDuty がサポートするリージョンは上記 17 以外にも存在します（ap-southeast-3, ca-west-1, eu-central-2 等）。オプトインリージョンを含めるかどうかはプロジェクトの要件に応じて判断してください。

---

## 検証手順

構築完了後、以下の手順で動作確認を行ってください：

```bash
# 1. フォーマット・検証
terraform fmt -recursive
terraform validate

# 2. Plan 確認（import/moved の結果を確認）
terraform plan

# 3. Apply
terraform apply

# 4. サンプル Finding で Slack 通知テスト
aws guardduty create-sample-findings \
  --detector-id <detector_id> \
  --finding-types UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration \
  --region <集約リージョン>
# → Slack チャンネルに通知が届くことを確認
```

---

## 既存 Detector ID の一括取得コマンド

```bash
for region in $(aws account list-regions \
  --region-opt-status-contains ENABLED_BY_DEFAULT \
  --query 'Regions[].RegionName' --output text); do
  id=$(aws guardduty list-detectors --region "$region" --query 'DetectorIds[0]' --output text 2>/dev/null)
  key=$(echo "$region" | tr '-' '_')
  echo "    ${key} = \"${id}\""
done
```
