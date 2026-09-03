# SecurityHub Finding Aggregator — Terraform 構築プロンプト

[English version](securityhub-finding-aggregator.md)

## 概要

SecurityHub のクロスリージョン Finding 集約機能を利用して、GuardDuty の Finding（MEDIUM 以上）を AWS Chatbot 経由で Slack に通知するパイプラインを構築してください。これは [GuardDuty 全リージョン一元管理](guardduty-multiregion-setup.ja.md) の通知セクションで記載されている**リージョン別 EventBridge 転送方式の代替手段**です。

SecurityHub の組み込みクロスリージョン レプリケーションを活用することで、各リージョンの通知リソース（EventBridge 転送ルール、Custom Event Bus、転送用 IAM Role）をすべて不要にします。

### 方式比較

| 比較項目 | EventBridge 転送方式 | SecurityHub Aggregator 方式 |
|---|---|---|
| 各リージョンの通知リソース | 2（Rule + Target） | **0** |
| 通知リソース合計 | ~45 | **~10** |
| リージョン追加時の作業 | 手動（Rule + Target 追加） | **不要（自動）** |
| Custom Event Bus | 必要 | **不要** |
| クロスリージョン IAM Role | 必要 | **不要** |
| SecurityHub 依存 | なし | あり（多くの場合すでに有効） |

### 用語定義

| 用語 | 意味 |
|---|---|
| **集約リージョン** | SecurityHub が全リンクリージョンの Finding を集約するリージョン。EventBridge ルールと SNS 通知はこのリージョンにのみ配置する |
| **リンクリージョン** | Finding Aggregator 経由で集約リージョンに Finding がレプリケートされるリージョン |
| **ASFF** | AWS Security Finding Format — SecurityHub が使用する標準化された Finding フォーマット。GuardDuty の Finding は SecurityHub にインポートされる際に自動的に ASFF に変換される |

> **スコープ**: 本レシピは通知パイプラインのみを対象とします。GuardDuty のコアリソース（Detector、メンバー、Feature、Organization 設定）は [GuardDuty 全リージョン一元管理](guardduty-multiregion-setup.ja.md) で別途セットアップしてください（コアセクションのみ使用し、通知セクションは不要）。

---

## アーキテクチャ

```
[全リージョン]
  GuardDuty Detector
      ↓ (自動インポート)
  SecurityHub ──(Finding Aggregator がレプリケート)──→ [集約リージョン]
                                                        SecurityHub
                                                            ↓
                                                      EventBridge Rule (MEDIUM+)
                                                            ↓
                                                        SNS Topic
                                                            ↓
                                                       AWS Chatbot
                                                            ↓
                                                          Slack
```

### EventBridge 転送方式との比較

```
# EventBridge 転送方式（各リージョンにリソースが必要）:
[Region A] GuardDuty → EventBridge Rule → ─┐
[Region B] GuardDuty → EventBridge Rule → ─┼→ Custom EventBus → EventBridge Rule → SNS → Slack
[Region C] GuardDuty → EventBridge Rule → ─┘   ↑ IAM Role
                                                ↑ Bus Policy
# 非集約リージョンあたり: 2 リソース（Rule + Target）
# 集約リージョン: 10 リソース（Bus, Policy, Rule×2, Target×2, IAM Role, Role Policy, SNS, SNS Policy）

# SecurityHub Aggregator 方式（各リージョンのリソース不要）:
[Region A] GuardDuty → SecurityHub ──┐
[Region B] GuardDuty → SecurityHub ──┼─(自動レプリケート)─→ SecurityHub → EventBridge Rule → SNS → Slack
[Region C] GuardDuty → SecurityHub ──┘
# 合計: Aggregator 1 + Rule 1 + Target 1 + SNS 1 + SNS Policy 1 = 通知リソース 5 つ
```

---

## 前提条件

| 項目 | 説明 |
|---|---|
| **GuardDuty** | 対象リージョンで Detector が有効化済み（[GuardDuty 全リージョン一元管理](guardduty-multiregion-setup.ja.md) を参照） |
| **SecurityHub** | 対象リージョンおよび集約リージョンで有効化済み。AWS Control Tower により事前設定されていることが多い |
| **集約リージョン** | 通知を一元化するリージョン（例: `ap-northeast-1`） |
| **Slack workspace ID** | AWS Chatbot と連携する Slack ワークスペース ID |
| **Slack channel ID** | GuardDuty Finding の通知先 Slack チャンネル ID |
| **Terraform backend** | S3 バケット名、key、リージョン |

### 事前準備

- AWS Chatbot コンソールで Slack ワークスペースとの連携を設定しておくこと（Terraform では Slack workspace の連携自体は管理できない）
- SecurityHub が対象リージョンで未有効の場合、各リージョンの設定に `aws_securityhub_account` を追加するか、AWS Organizations 経由で有効化すること

### SecurityHub のリージョン別有効化（未有効の場合）

Control Tower で管理されていない場合、[guardduty-region モジュール](guardduty-multiregion-setup.ja.md) に以下を追加してください：

```hcl
resource "aws_securityhub_account" "this" {}
```

Organizations 全体の自動有効化（集約リージョンでのみ設定）：

```hcl
resource "aws_securityhub_organization_admin_account" "this" {
  admin_account_id = var.delegated_admin_account_id
}

resource "aws_securityhub_organization_configuration" "this" {
  auto_enable           = true
  auto_enable_standards = "DEFAULT"
  depends_on            = [aws_securityhub_organization_admin_account.this]
}
```

---

## ディレクトリ構成

```
terraform/
├── env/management/
│   ├── backend.tf                               # Provider（集約リージョン）
│   ├── locals.tf                                # project / account ID / Slack 設定
│   ├── guardduty.tf                             # GuardDuty コア モジュール呼び出し（既存レシピ）
│   ├── guardduty_notification.tf                # 通知モジュール呼び出し
│   └── chatbot.tf                               # AWS Chatbot Slack 連携
│
└── modules/management/guardduty-notification/    # SecurityHub Aggregator + EventBridge + SNS
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    └── versions.tf
```

---

## 構築手順

### Step 1: modules/management/guardduty-notification/ — 通知モジュール

#### variables.tf

```hcl
variable "project" {
  description = "リソース命名に使用するプロジェクト名"
  type        = string
}

variable "severity_labels" {
  description = "通知対象の SecurityHub 重要度ラベル"
  type        = list(string)
  default     = ["MEDIUM", "HIGH", "CRITICAL"]
}
```

#### main.tf

```hcl
# =============================================================================
# SecurityHub Finding Aggregator
# =============================================================================

resource "aws_securityhub_finding_aggregator" "this" {
  linking_mode = "ALL_REGIONS"
}

# =============================================================================
# EventBridge — SecurityHub 経由の GuardDuty Finding
# =============================================================================

resource "aws_cloudwatch_event_rule" "guardduty_findings" {
  name        = "${var.project}-guardduty-findings"
  description = "GuardDuty Finding (${join("/", var.severity_labels)}) を SecurityHub 集約経由で SNS にルーティング"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        ProductName = ["GuardDuty"]
        Severity = {
          Label = var.severity_labels
        }
        # Imported イベントは新規だけでなく更新でも発火するため、未対応かつ ACTIVE な Finding だけ通知する
        Workflow = {
          Status = ["NEW"]
        }
        RecordState = ["ACTIVE"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_to_sns" {
  rule      = aws_cloudwatch_event_rule.guardduty_findings.name
  target_id = "guardduty-sns"
  arn       = aws_sns_topic.guardduty_findings.arn

  input_transformer {
    input_paths = {
      account     = "$.detail.findings[0].AwsAccountId"
      region      = "$.detail.findings[0].Region"
      severity    = "$.detail.findings[0].Severity.Label"
      title       = "$.detail.findings[0].Title"
      description = "$.detail.findings[0].Description"
      type        = "$.detail.findings[0].Types[0]"
      firstSeen   = "$.detail.findings[0].FirstObservedAt"
    }
    input_template = "\"[GuardDuty] <title>\\n\\nAccount:    <account>\\nRegion:     <region>\\nSeverity:   <severity>\\nType:       <type>\\nFirst Seen: <firstSeen>\\n\\n<description>\""
  }
}

# =============================================================================
# SNS Topic
# =============================================================================

resource "aws_sns_topic" "guardduty_findings" {
  name = "${var.project}-guardduty-findings"
}

resource "aws_sns_topic_policy" "guardduty_findings" {
  arn = aws_sns_topic.guardduty_findings.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.guardduty_findings.arn
      }
    ]
  })
}
```

#### outputs.tf

```hcl
output "sns_topic_arn" {
  description = "GuardDuty findings SNS Topic ARN"
  value       = aws_sns_topic.guardduty_findings.arn
}

output "event_rule_arn" {
  description = "GuardDuty findings EventBridge Rule ARN"
  value       = aws_cloudwatch_event_rule.guardduty_findings.arn
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

### Step 2: env/management/guardduty_notification.tf — モジュール呼び出し

```hcl
module "guardduty_notification" {
  source  = "../../modules/management/guardduty-notification"
  project = local.project
}
```

---

### Step 3: env/management/chatbot.tf — Slack 通知（AWS Chatbot）

> **事前準備**: AWS Chatbot コンソールで Slack ワークスペースとの連携を完了させておく必要があります。Terraform では workspace の連携自体は管理できません。

```hcl
# --- IAM Role for AWS Chatbot ---
resource "aws_iam_role" "chatbot_guardduty" {
  name = "${local.project}-chatbot-guardduty"

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
  configuration_name = "${local.project}-guardduty-findings"
  iam_role_arn       = aws_iam_role.chatbot_guardduty.arn
  slack_channel_id   = "<Slack チャンネル ID>"
  slack_team_id      = "<Slack ワークスペース ID>"
  sns_topic_arns     = [module.guardduty_notification.sns_topic_arn]
  logging_level      = "ERROR"
}
```

---

## GuardDuty 全リージョン一元管理レシピとの統合

SecurityHub 方式を採用する場合、[GuardDuty 全リージョン一元管理](guardduty-multiregion-setup.ja.md) のモジュール呼び出しを以下のように変更してください。

### 残すもの

GuardDuty のコアリソースはすべてそのまま：
- `aws_guardduty_detector`
- `aws_guardduty_detector_feature`（全 Feature）
- `aws_guardduty_member`
- `aws_guardduty_organization_admin_account`
- `aws_guardduty_organization_configuration`
- `aws_guardduty_organization_configuration_feature`（全 Feature）

### 削除するもの

`guardduty-region` モジュールから通知関連の変数とリソースをすべて削除：

**削除する変数:**
- `is_aggregation_region`
- `management_account_id`
- `enable_finding_forwarding`
- `forwarding_event_bus_arn`
- `forwarding_role_arn`

**削除するリソース:**
- `aws_sns_topic.guardduty_findings`
- `aws_sns_topic_policy.guardduty_findings`
- `aws_cloudwatch_event_bus.guardduty_findings`
- `aws_cloudwatch_event_bus_policy.guardduty_findings`
- `aws_cloudwatch_event_rule.guardduty_default_bus`
- `aws_cloudwatch_event_target.guardduty_default_bus_to_sns`
- `aws_cloudwatch_event_rule.guardduty_custom_bus`
- `aws_cloudwatch_event_target.guardduty_custom_bus_to_sns`
- `aws_iam_role.guardduty_eventbridge_forwarding`
- `aws_iam_role_policy.guardduty_eventbridge_forwarding`
- `aws_cloudwatch_event_rule.guardduty_forward`
- `aws_cloudwatch_event_target.guardduty_forward`

**削除する Output:**
- `sns_topic_arn`
- `event_bus_arn`
- `forwarding_role_arn`

### 簡素化されたモジュール呼び出し

全リージョン同一の呼び出しになり、`is_aggregation_region` / `enable_finding_forwarding` の使い分けが不要に：

```hcl
module "guardduty_<region>" {
  source                     = "../../modules/management/guardduty-region"
  delegated_admin_account_id = local.delegated_admin_account_id
  member_accounts            = local.member_accounts
  providers                  = { aws = aws.<region> }
}
```

---

## 注意事項・Tips

### SecurityHub の挙動に関する注意

1. **Finding Aggregator はメタデータだけでなく Finding 自体をレプリケートする**
   - `linking_mode = "ALL_REGIONS"` を設定すると、全リンクリージョンの Finding が集約リージョンの SecurityHub にレプリケートされる。このレプリケーションにより集約リージョンで `Security Hub Findings - Imported` の EventBridge イベントが発火するため、1 つのルールで全リージョンの Finding を捕捉できる

2. **イベントは「Finding ごとに 1 回」ではなく「インポート・更新ごとに 1 回」**
   - `Security Hub Findings - Imported` は `BatchImportFindings` / `BatchUpdateFindings` の呼び出しごとに発火する。GuardDuty は同じ Finding に追加の観測があると更新を送り（更新頻度、既定 6 時間でまとめられる）、そのたびにイベントが再発火する。上のパターンは `Workflow.Status = NEW` かつ `RecordState = ACTIVE` に絞っており、対応済みの Finding は落とすが、未対応 Finding の更新は落とさない
   - Finding ごとに厳密に 1 回だけ通知したい場合は、初回通知後に Workflow を `NOTIFIED` に更新する（EventBridge ターゲットの Lambda から `BatchUpdateFindings`）。この更新自身も Imported イベントを 1 回発火させるので、処理は冪等にする。Compliance が PASSED → FAILED に戻ると Security Hub が `NOTIFIED` を `NEW` に戻すため、再発は拾える
   - リンク前から存在していた Finding は、次に更新されたときに初めて集約リージョンに複製される

3. **新リージョンは自動的にカバーされる**
   - `ALL_REGIONS` は将来のリージョンも含む。新リージョンで GuardDuty と SecurityHub を有効化すれば、Finding は自動的に集約リージョンに流れる — 追加の EventBridge ルールや転送設定は不要
   - Aggregator 自体は SecurityHub やオプトインリージョンを有効化しない。GuardDuty を有効にしているリージョンの集合とリンクリージョンの集合を一致させること。リンクしていないリージョンの Finding は通知されない

4. **SecurityHub は各リージョンで有効化が必要**
   - Finding Aggregator は SecurityHub の Finding を集約するのであり、GuardDuty の Finding を直接集約するわけではない。GuardDuty は Finding を SecurityHub に自動インポートするが、そのためには対象リージョンで SecurityHub が有効である必要がある

5. **ASFF フォーマットはネイティブ GuardDuty フォーマットと異なる**
   - EventBridge イベントはネイティブ GuardDuty イベント形式ではなく ASFF（AWS Security Finding Format）を使用する。フィールドパスが異なる（例: `$.detail.severity` ではなく `$.detail.findings[0].Severity.Label`）。本レシピの `input_transformer` は ASFF パスを使用している

### Terraform 実装の注意

1. **Finding Aggregator はアカウントにつき 1 つで、集約（ホーム）リージョンに作成する**
   - `aws_securityhub_finding_aggregator` はアカウント内に 1 つしか存在できず、集約リージョンの provider で作成する。既に設定済み（例: Control Tower による設定）の場合は import で取り込むこと

2. **既存 Finding Aggregator の import**
   ```hcl
   import {
     to = module.guardduty_notification.aws_securityhub_finding_aggregator.this
     id = "<finding_aggregator_arn>"
   }
   ```
   ARN の取得：
   ```bash
   aws securityhub list-finding-aggregators --region <集約リージョン> \
     --query 'FindingAggregators[0].FindingAggregatorArn' --output text
   ```

3. **SecurityHub Organization admin は既に指定されている可能性がある**
   - Control Tower が SecurityHub を管理している場合、delegated admin は management account ではなく Audit アカウントになっている可能性がある。`aws_securityhub_organization_admin_account` を追加する前に確認すること

---

## 検証手順

```bash
# 1. フォーマット・検証
terraform fmt -recursive
terraform validate

# 2. Plan 確認
terraform plan

# 3. Apply
terraform apply

# 4. Finding Aggregator の稼働確認
aws securityhub list-finding-aggregators \
  --region <集約リージョン> \
  --query 'FindingAggregators[0].{ARN:FindingAggregatorArn,Regions:RegionLinkingMode}' \
  --output table

# 5. 非集約リージョンからのサンプル Finding でテスト
aws guardduty create-sample-findings \
  --detector-id <detector_id> \
  --finding-types UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration \
  --region <非集約リージョン>
# → Slack チャンネルに通知が届くことを確認
#   （Finding の流れ: GuardDuty → SecurityHub → Aggregator → EventBridge → SNS → Chatbot → Slack）

# 6. 集約リージョンからもテスト
aws guardduty create-sample-findings \
  --detector-id <detector_id> \
  --finding-types UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration \
  --region <集約リージョン>
# → 直接パス（クロスリージョン不要）で通知が届くことを確認
```
