# AWS Health 通知 via EventBridge — Terraform 構築プロンプト

[English version](health-notification-via-eventbridge.md)

## 概要

**EventBridge us-west-2 集約**（2025年11月〜）を利用して、標準パーティション全リージョンのアカウント固有 AWS Health イベントを 1 ルールで捕捉し（public イベントはこの経路では届かず、グローバルサービスのイベントは us-east-1 に配信される）、Knowledge Base 搭載の AI 分析パイプラインを経由して Slack に通知する構成を構築してください。

### なぜ us-west-2 か？

AWS Health は各イベントを影響リージョンとバックアップリージョンの両方に配信します。標準パーティションでは **us-west-2** が他の全リージョンのバックアップリージョンです（us-west-2 自身のバックアップは us-east-1）。そのため us-west-2 に 1 つの EventBridge ルールを置くだけで、全リージョンの**アカウント固有**の Health イベントを捕捉できます。リージョンごとのルールやクロスリージョン転送は不要です。

制約が 2 つあります。**public イベント**（AWS Health Dashboard に出るサービス全体の障害）はこの経路では届きません。**グローバルサービスのイベント**（IAM、Route 53、CloudFront、請求）は us-east-1 に配信されるので、必要なら us-east-1 にもルールを置きます。

### 方式比較

| 方式 | クロスリージョン | 全イベント種別 | リアルタイム | 複雑度 |
|---|---|---|---|---|
| **EventBridge us-west-2（本レシピ）** | **全リージョン（アカウント固有イベント）** | **全カテゴリ** | **即時** | **低** |
| SecurityHub Finding Aggregator | 全リージョン | セキュリティ系のみ | 即時 | 中 |
| Health Organizational View | 全アカウント（管理アカウント / 委任管理者に EventBridge の 1 フィード） | 全カテゴリ | 即時 | 低 |
| AWS Health Aware (AHA) | 全リージョン | 全種別 | ポーリング（遅延あり） | 高 |

> **注意**: SecurityHub は*セキュリティ関連*の Health イベントのみ受信します。オペレーション系イベント（メンテナンス、サービス障害等）は SecurityHub に入りません。本レシピは全イベント種別を捕捉します。

### 用語定義

| 用語 | 意味 |
|---|---|
| **集約リージョン** | us-west-2 — 1 つの EventBridge ルールで全リージョンのアカウント固有 Health イベントを捕捉するリージョン（バックアップ配信） |
| **処理リージョン** | Lambda、Bedrock KB、DynamoDB、Scheduler を配置するリージョン（例: `ap-northeast-1`） |
| **eventTypeCategory** | Health イベントの分類: `issue`、`accountNotification`、`scheduledChange`、`investigation` |

---

## アーキテクチャ

```
[全リージョン]
  AWS Health Event
      ↓ (バックアップリージョン us-west-2 にも配信)

[us-west-2]
  EventBridge Rule (source=aws.health)
      ↓ (クロスリージョンターゲット)

[処理リージョン, e.g. ap-northeast-1]
  EventBridge (custom bus: health-events)
      ↓
  EventBridge Rule → SNS Topic
      ↓
  Triage Lambda
      ├── issue (open) → IMMEDIATE: KB + Claude → Slack
      ├── accountNotification → HOURLY: DynamoDB → 毎時ダイジェスト
      └── scheduledChange → DAILY: DynamoDB → 毎日10:00 JST ダイジェスト

  EventBridge Scheduler (毎時/毎日)
      → Digest Lambda → DynamoDB → KB + Claude バッチ → Slack ダイジェスト
```

---

## 前提条件

| 項目 | 説明 |
|---|---|
| **AWS Organizations**（複数アカウントの場合のみ） | 管理アカウントで組織ビューを有効化し、1 つのアカウントで全アカウントの Health フィードを受ける。コンソールからの有効化は全サポートプランで可能、CLI / API は Business、Enterprise On-Ramp、Enterprise サポートが必要。Terraform リソースは無いので手動の前提条件として扱う |
| **処理リージョン** | Lambda/KB リソースを配置するリージョン（例: `ap-northeast-1`） |
| **Slack webhook** | Slack Incoming Webhook URL |
| **Terraform providers** | us-west-2（集約）と処理リージョンの provider alias |
| **Bedrock アクセス** | 処理リージョンで Claude Sonnet と Titan Embed v2 が利用可能であること |

---

## イベント分類（バッチング tier）

| eventTypeCategory | statusCode | Tier | 通知 |
|---|---|---|---|
| `issue` | `open` | IMMEDIATE | 即時 AI 分析 + Slack |
| `investigation` | any | IMMEDIATE | 即時 AI 分析 + Slack（AWS がアカウント内の活動を調査中） |
| `issue` | `closed` | DAILY | デイリーダイジェスト |
| `accountNotification` | any | HOURLY | 毎時ダイジェスト |
| `scheduledChange` | `upcoming` | DAILY | デイリーダイジェスト (10:00 JST) |
| `scheduledChange` | `open` / `closed` | DAILY | デイリーダイジェスト |

---

## ディレクトリ構成

```
terraform/
├── env/management/
│   ├── backend.tf
│   ├── locals.tf
│   └── health_knowledge_analysis.tf     # モジュール呼び出し
│
└── modules/health-knowledge-analysis/
    ├── eventbridge.tf                    # us-west-2 ルール + クロスリージョン + 処理リージョンルール + SNS
    ├── lambda.tf                         # Triage Lambda + SNS サブスクリプション
    ├── digest_lambda.tf                  # Digest Lambda + Scheduler パーミッション
    ├── knowledge_base.tf                 # Bedrock KB + S3 Vectors + データソース
    ├── s3.tf                             # S3 バケット (docs + history)
    ├── dynamodb.tf                       # イベントキューテーブル
    ├── scheduler.tf                      # EventBridge Scheduler (毎時 + 毎日) + DLQ
    ├── iam.tf                            # Triage Lambda IAM
    ├── variables.tf
    ├── outputs.tf
    ├── locals.tf
    ├── data.tf
    └── src/
        ├── common.py                     # 共通ユーティリティ（KB、Claude、Slack、サニタイズ）
        ├── index.py                      # Triage ハンドラ
        └── digest.py                     # Digest ハンドラ
```

---

## 構築手順

### Step 1: eventbridge.tf — クロスリージョンイベント捕捉

モジュールには**2つの provider** が必要: 処理リージョン用のデフォルト provider と、集約リージョン用の `us_west_2` alias。

```hcl
# --- us-west-2: 全リージョンのアカウント固有 Health イベントを捕捉 ---
resource "aws_cloudwatch_event_rule" "health_all_regions" {
  provider    = aws.us_west_2
  name        = "${var.project_name}-health-all-regions"
  description = "us-west-2 のバックアップ配信経由で全リージョンのアカウント固有 AWS Health イベントを捕捉"

  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail-type = ["AWS Health Event", "AWS Health Abuse Event"]
  })
}

# --- 処理リージョンへのクロスリージョン転送 ---
resource "aws_cloudwatch_event_bus" "health_events" {
  name = "${var.project_name}-health-events"
}

resource "aws_cloudwatch_event_bus_policy" "health_events" {
  event_bus_name = aws_cloudwatch_event_bus.health_events.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCrossRegionPutEvents"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "events:PutEvents"
      Resource  = aws_cloudwatch_event_bus.health_events.arn
    }]
  })
}

resource "aws_iam_role" "eventbridge_forwarding" {
  provider = aws.us_west_2
  name     = "${var.project_name}-health-eb-forwarding"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_forwarding" {
  provider = aws.us_west_2
  name     = "${var.project_name}-health-eb-forwarding"
  role     = aws_iam_role.eventbridge_forwarding.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "events:PutEvents"
      Resource = aws_cloudwatch_event_bus.health_events.arn
    }]
  })
}

resource "aws_cloudwatch_event_target" "forward_to_processing" {
  provider  = aws.us_west_2
  rule      = aws_cloudwatch_event_rule.health_all_regions.name
  target_id = "forward-health-events"
  arn       = aws_cloudwatch_event_bus.health_events.arn
  role_arn  = aws_iam_role.eventbridge_forwarding.arn
}

# --- 処理リージョン: custom bus → SNS ---
resource "aws_cloudwatch_event_rule" "health_to_sns" {
  name           = "${var.project_name}-health-to-sns"
  event_bus_name = aws_cloudwatch_event_bus.health_events.name
  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail-type = ["AWS Health Event", "AWS Health Abuse Event"]
  })
}

resource "aws_cloudwatch_event_target" "health_to_sns" {
  rule           = aws_cloudwatch_event_rule.health_to_sns.name
  event_bus_name = aws_cloudwatch_event_bus.health_events.name
  target_id      = "health-sns"
  arn            = aws_sns_topic.health_events.arn
}

resource "aws_sns_topic" "health_events" {
  name = "${var.project_name}-health-events"
}

resource "aws_sns_topic_policy" "health_events" {
  arn = aws_sns_topic.health_events.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgePublish"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.health_events.arn
    }]
  })
}
```

### Step 2: Lambda、Knowledge Base、DynamoDB、Scheduler

[SecurityHub Finding Aggregator](securityhub-finding-aggregator.ja.md) の GuardDuty Knowledge Analysis と同じパターンに従います。Lambda コードの主な違い:

**イベントパース** — Health イベントは異なる構造:
```python
def parse_health_event(message_str):
    event = json.loads(message_str)
    detail = event.get("detail", {})
    return {
        "event_arn": detail.get("eventArn", ""),
        "service": detail.get("service", ""),
        "event_type_code": detail.get("eventTypeCode", ""),
        "event_type_category": detail.get("eventTypeCategory", ""),
        "region": detail.get("eventRegion", ""),          # 影響リージョン（トップレベルの "region" は配信先リージョン）
        "status_code": detail.get("statusCode", ""),
        "start_time": detail.get("startTime", ""),
        "end_time": detail.get("endTime", ""),
        "description": detail.get("eventDescription", [{}])[0].get("latestDescription", ""),
        "affected_entities": detail.get("affectedEntities", []),
        "account_id": detail.get("affectedAccount", event.get("account", "")),  # 組織ビューではトップレベルの "account" は受信アカウント
        "communication_id": detail.get("communicationId", ""),
        "page": detail.get("page", "1"),
        "total_pages": detail.get("totalPages", "1"),
    }
```

**重要度分類** — `eventTypeCategory` + `statusCode` ベース:
```python
def classify_health_event(event_info):
    category = event_info["event_type_category"]
    status = event_info["status_code"]
    if category == "issue" and status == "open":
        return "IMMEDIATE"
    elif category == "investigation":
        return "IMMEDIATE"
    elif category == "accountNotification":
        return "HOURLY"
    return "DAILY"
```

**システムプロンプト** — Health イベント分析用:
```python
SYSTEM_PROMPT = (
    "あなたはAWSインフラ運用のエキスパートです。"
    "AWS Health イベントを分析し、運用チームに対して影響評価と対応手順を日本語で提供してください。..."
)
```

### Step 3: モジュール呼び出し

```hcl
module "health_knowledge_analysis" {
  source = "../../modules/health-knowledge-analysis"

  environment        = local.environment
  slack_webhook_path = var.health_analysis_slack_webhook_path

  providers = {
    aws           = aws            # ap-northeast-1
    aws.us_west_2 = aws.us_west_2  # us-west-2
  }
}
```

---

## 注意事項・Tips

### AWS Health の挙動に関する注意

1. **us-west-2 は全リージョンのアカウント固有イベントを受信する（バックアップ配信）**
   - アカウント固有の Health イベントにはリージョンごとの EventBridge ルールは不要
   - us-west-2 は他の全リージョンのバックアップ、us-east-1 は us-west-2 のバックアップのみ
   - public イベントは含まれない。必要ならリソースのあるリージョンにルールを残す
   - バックアップ配信のコピーは `detail.backupEvent = true` を持つ。同じアカウントでリージョン別ルールも併用する場合はフィルタか重複排除が必要

2. **グローバルイベント（IAM、Route53、CloudFront）は us-east-1 に配信される**
   - 完全なカバレッジには us-east-1 にも補助ルールを追加
   - us-west-2 には届かない。us-east-1 が us-west-2 のバックアップであり、逆ではない

3. **SecurityHub はセキュリティ関連の Health イベントのみ受信する**
   - オペレーション系イベント（メンテナンス、非推奨化、サービス障害）は SecurityHub を通らない
   - 本レシピは EventBridge 直接統合で全イベント種別を捕捉

4. **Health 組織ビューはアカウントを横断する（リージョンは横断しない）**
   - 管理アカウントで有効化（メンバーアカウントへの委任も可）すると、そのアカウントが組織内全アカウントの Health イベントを EventBridge の 1 フィードで受信できる。そのアカウントに本レシピの us-west-2 ルールを置けば、複数アカウント × 複数リージョンをカバーできる
   - コンソールからの有効化は全サポートプランで可能。CLI / API（`aws health enable-health-service-access-for-organization --region us-east-1`）は Business、Enterprise On-Ramp、Enterprise サポートが必要。Terraform リソースは無い

### イベント重複排除

- `eventArn` はアカウント・リージョンをまたいで一意ではない。イベント状態のキーは `affectedAccount` + `eventArn`、配信重複（バックアップ配信・再試行）の排除は `affectedAccount` + `communicationId`（ページ番号を含む）で行う
- イベントは更新される場合がある（statusCode: `upcoming` → `open` → `closed`）
- 条件付き UpdateItem で最新版を保持（GuardDuty の Finding 更新と同じパターン）

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

# 4. us-west-2 の EventBridge ルールを確認
aws events list-rules --region us-west-2 \
  --query "Rules[?contains(Name, 'health')]"

# 5. クロスリージョンターゲットを確認
aws events list-targets-by-rule \
  --rule <ルール名> --region us-west-2

# 6. 実際の Health イベント発生を待つか、EventBridge のテストイベント機能でテスト
```
