# GuardDuty 全リージョン一元管理 — Terraform 構築プロンプト

## 概要

AWS Organizations 環境において、GuardDuty を対象リージョンで有効化し、単一の Terraform ワークスペース（management 環境）から一元管理する構成を構築してください。MEDIUM 以上の Finding はメール通知します。

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
| **通知先メールアドレス** | GuardDuty Finding のメール通知先 |
| **Terraform backend** | S3 バケット名、key、リージョン |
| **既存 Detector ID** | 各リージョンで既に GuardDuty が有効な場合、その Detector ID（`aws guardduty list-detectors --region <region>` で取得） |

### コスト確認

GuardDuty を全リージョン・全アカウントで有効化すると、EBS Malware Protection・Runtime Monitoring 等の保護機能により課金が発生します。apply 前に AWS の料金ページで費用影響を確認してください。

---

## ディレクトリ構成

```
terraform/
├── env/management/                             # 単一 tfstate で全リージョン管理
│   ├── backend.tf                              # provider alias + S3 backend
│   ├── locals.tf                               # project / environment / account ID / regions
│   ├── guardduty.tf                            # import + module 呼出 + outputs
│   ├── guardduty-notifications.tf              # EventBridge 集約 → SNS → メール
│
└── modules/management/guardduty-region/         # 1 リージョン分の GuardDuty 設定
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    └── versions.tf
```

---

## 構築手順

### Step 1: modules/management/guardduty-region/ — 共通モジュール

1 リージョン分の GuardDuty 設定をモジュール化します。このモジュールを対象リージョン数だけ呼び出すことで全リージョンに同一設定を展開します。

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
```

#### outputs.tf

```hcl
output "detector_id" {
  description = "GuardDuty Detector ID"
  value       = aws_guardduty_detector.this.id
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

対象リージョンごとにモジュールを呼び出します：

```hcl
module "guardduty_<aggregation_region>" {
  source                     = "../../modules/management/guardduty-region"
  delegated_admin_account_id = local.delegated_admin_account_id
  member_accounts            = local.member_accounts
  providers                  = { aws = aws }  # デフォルト provider（集約リージョン）
}

module "guardduty_<other_region>" {
  source                     = "../../modules/management/guardduty-region"
  delegated_admin_account_id = local.delegated_admin_account_id
  member_accounts            = local.member_accounts
  providers                  = { aws = aws.<other_region> }
}

# ... 対象リージョンすべてについて同様
```

#### outputs

各リージョンの Detector ID を出力：

```hcl
output "guardduty_detector_id_<region>" {
  description = "GuardDuty Detector ID (<region>)"
  value       = module.guardduty_<region>.detector_id
}
```

---

### Step 5: env/management/guardduty-notifications.tf — メール通知

全リージョンの MEDIUM 以上（severity >= 4.0）の Finding を集約リージョンに集約してメール通知します。通知リソースは delegated admin アカウント（= management account）上に作成します。

#### アーキテクチャ

```
[集約リージョン]
  default EventBus → EventBridge Rule → SNS Topic → Email
  custom  EventBus "guardduty-findings" → EventBridge Rule → SNS Topic → Email

[他リージョン]
  default EventBus → EventBridge Rule → 集約リージョンの custom EventBus に転送
```

#### 必要リソース

1. **SNS Topic + Email Subscription** (集約リージョン)
   - Topic: `guardduty-findings`
   - Topic Policy: `events.amazonaws.com` に `sns:Publish` を許可
   - Subscription: `protocol = "email"`, `endpoint = "<通知先メール>"`
   - **注意**: apply 後に通知先メールアドレスへ確認メールが届くため、手動で承認が必要

2. **Custom Event Bus** (集約リージョン)
   - Name: `guardduty-findings`
   - Bus Policy: 自アカウントからの `events:PutEvents` を許可

3. **EventBridge Rule: 集約リージョン default bus → SNS**
   - event_pattern: `source=aws.guardduty, detail-type=GuardDuty Finding, detail.severity >= 4`
   - target: SNS Topic
   - input_transformer で整形（Account/Region/Severity/Type/Description + コンソールリンク）

4. **EventBridge Rule: custom bus → SNS**
   - 他リージョンから転送された Finding を SNS へ
   - 同じ input_transformer を使用

5. **IAM Role** (IAM はグローバルサービスだが、Terraform 上はデフォルト provider（集約リージョン）で作成)
   - 信頼ポリシー: `events.amazonaws.com`
   - 権限: `events:PutEvents` on `arn:aws:events:<集約リージョン>:<account>:event-bus/guardduty-findings`

6. **各リージョンの転送ルール** (集約リージョン以外 × 各 1 つ)
   - 各 provider alias を使用して EventBridge Rule + Target を作成
   - event_pattern: severity >= 4.0 のフィルタ
   - target: 集約リージョンの custom event bus ARN
   - role_arn: 上記 IAM Role

#### Input Transformer テンプレート例

```hcl
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

6. **SNS Email Subscription は手動承認が必要**
   - `terraform apply` 後に通知先メールアドレスへ確認メールが届く。承認しないと通知が届かない

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

# 4. SNS Email Subscription の承認
#    通知先メールアドレスに届いた確認メールで "Confirm subscription" をクリック

# 5. サンプル Finding で通知テスト
aws guardduty create-sample-findings \
  --detector-id <detector_id> \
  --finding-types UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration \
  --region <集約リージョン>
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
