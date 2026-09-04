# セキュリティ通知の配送トポロジー — finding をどこに集約するか

[English](security-notification-topology.md) · [図・マトリクス (HTML)](docs/security-notification-topology.html) · [Terraform examples](examples/security-notification-topology/)

## 概要

Security Hub、GuardDuty、Inspector、AWS Health は、それぞれ「事象が起きたアカウント・リージョン」で finding やイベントを出す。これらを 1 つの Slack チャンネル（または 1 つの調査パイプライン）に集めるには、EventBridge ルールと SNS トピックを**どのアカウントの、どのリージョンに置くか**を決める必要がある。本ガイドはその判断を 3 つのアカウント構成について示し、アカウント × リージョン × サービスごとに「どの AWS の仕組みでデータが動くか」を明記する。

本リポジトリの 3 レシピは、以下のトポロジーの部品として使う。

| 部品 | レシピ |
|---|---|
| マルチリージョン GuardDuty（Detector・機能・Organizations） | [GuardDuty Multi-Region Management](guardduty-multiregion-setup.ja.md) |
| Security Hub のリージョン集約で通知ルールを 1 本にする | [SecurityHub Finding Aggregator](securityhub-finding-aggregator.ja.md) |
| AWS Health の捕捉（us-west-2 バックアップ配信・AI ダイジェスト） | [AWS Health Notification via EventBridge](health-notification-via-eventbridge.ja.md) |

対象: Security Hub **CSPM**（finding 集約サービス）。新しい Security Hub は委任管理者の制約が異なるため、該当箇所で注記する。例に使うリージョンはホームが `ap-northeast-1`、グローバルサービスのイベント用に `us-east-1`。

---

## 4 つの仕組み

これらは独立した機能で、1 本のパイプラインではない。finding は複数の仕組みを順に通ることもあり、Health イベントは最後の 1 つしか通らない。

| 仕組み | 越えるもの | 内容 | 対象サービス |
|---|---|---|---|
| **委任** | アカウント | Organizations の管理アカウントが委任管理者を指定する。メンバーの finding は管理者アカウントの**同じリージョン**に複製される。Health では組織ビューにより全アカウント分が 1 つの EventBridge フィードになる | Security Hub、GuardDuty、Inspector（委任管理者）、Health（組織ビュー。委任も可） |
| **集約** | リージョン | Security Hub のリージョン集約。リンクリージョンの finding をホームリージョンに複製する。Security Hub にしか無い | Security Hub |
| **統合** | サービス | 同アカウント・同リージョンの Security Hub が GuardDuty / Inspector（全 finding）と Health（セキュリティ関連のみ。MEDIUM 中心）の finding を取り込む | Security Hub ← GuardDuty / Inspector / Health |
| **直通** | — | EventBridge ルールが同リージョンの SNS トピックに発行する。通知経路は直通ルールを置いたリージョンにしか存在しない | 全サービス |

設計を決める帰結:

- GuardDuty と Inspector は**統合 → 集約**でホームリージョンに届くので、GuardDuty ネイティブの EventBridge ルールは不要。両方置くと同じ finding が 2 回通知される。
- Health は**集約が無く**、統合も一部のため、イベントを受けるリージョンごとに直通ルールが要る。ワークロードのあるリージョン、グローバルサービス（IAM、Route 53、CloudFront、請求）用の `us-east-1`、任意で全リージョンのアカウント固有イベントをバックアップ配信で受ける `us-west-2`。detail-type は `AWS Health Event` と `AWS Health Abuse Event` の両方を対象にする。
- Inspector の finding も GuardDuty と同じ経路でホームリージョンに届くが、examples では `ProductName = Inspector` を既定で Slack 通知から除外している。CVE の finding は大量に届くためコンソールで確認する方が向く。HIGH / CRITICAL の脆弱性も通知したければ `excluded_product_names` から外す。
- `Security Hub Findings - Imported` はインポートだけでなく**更新でも**発火する。`Workflow.Status = NEW` と `RecordState = ACTIVE` で絞り、失敗の発生ごとに 1 回だけ通知したいなら初回通知後に `NOTIFIED` にする（Compliance が PASSED → FAILED に戻ると Security Hub が `NEW` に戻す）。

---

## ケースの選び方

```
Organizations の管理アカウントが委任管理者を指定してくれるか？
├─ いいえ → ケース 3: 1 メンバーアカウント
└─ はい   → セキュリティ専用アカウントを用意（または流用）できるか？
            ├─ はい → ケース 1: 委任管理者 = セキュリティ集約アカウント（推奨）
            └─ いいえ → ケース 2: 管理アカウント = セキュリティ集約アカウント（動くが非推奨）
```

ケース 2 は AWS が非推奨としている。管理アカウントには SCP が効かず、管理アカウントでしかできない作業以外は置かないのが原則。さらに **Security Hub の中央設定と両立しない**（中央設定では管理アカウントを委任管理者にできない）ため、メンバーの設定をリージョンごとに揃える作業が残る。

---

## ケース 1 — 委任管理者 = セキュリティ集約アカウント（推奨）

| アカウント | リージョン | Security Hub | GuardDuty / Inspector | AWS Health | 通知経路 |
|---|---|---|---|---|---|
| 管理 | 全て | セキュリティアカウントを委任管理者に指定（**委任**）。自身では有効化しない | 同じアカウントをリージョンごとに指定（**委任**） | 組織ビューを有効化（コンソールなら全サポートプラン）し、セキュリティアカウントを Health の委任管理者に登録（**委任**） | 置かない |
| セキュリティ集約 | `ap-northeast-1`（ホーム） | 管理者。全メンバーの東京分を受信（**委任**）、`us-east-1` 分は**集約**で到着。中央設定の設定ポリシーで全メンバーの有効化と標準を一括管理 | 管理者。メンバーの finding を受信（**委任**）し Security Hub へ**統合** | 東京発イベントの組織ビューフィード | **直通**: Security Hub ルール（重要度 / Workflow で絞る）+ Health ルール → SNS 東京 → Chatbot / Lambda |
| セキュリティ集約 | `us-east-1`（リンク） | 管理者。finding は東京へ**集約**。ルールは置かない | 管理者。**統合 → 集約** | グローバルサービスと `us-east-1` 発（+ `us-west-2` バックアップ）の組織ビューフィード | **直通**: Health ルールのみ → SNS us-east-1 → Chatbot / Lambda（クロスリージョン購読） |
| メンバー（dev、prod、…） | 各 | メンバー。設定ポリシーで有効化・標準が適用される。finding は管理者へ複製（**委任**） | メンバー。自動有効化。**統合 → 委任** | 発生元 | 置かない |

Terraform の配置: state を分けた 2 つの root、`management/`（委任のみ）と `security/`（集約・検知・通知）。provider alias は**アカウント × リージョン**ごとに必要で、それぞれ自アカウントの専用ロールを assume する。

## ケース 2 — 管理アカウント = セキュリティ集約アカウント（やむを得ない場合）

| アカウント | リージョン | Security Hub | GuardDuty / Inspector | AWS Health | 通知経路 |
|---|---|---|---|---|---|
| 管理 = 集約 | `ap-northeast-1`（ホーム） | 自分自身を委任管理者に（**委任**、ローカル構成のみ。手動で Security Hub を有効化）。メンバーの finding を受信、`us-east-1` 分は**集約**。設定ポリシーは使えない | 自分自身を委任管理者に（**委任**、公式に非推奨）。リージョンごとに自動有効化。**統合** | 組織ビューは管理アカウントのまま。委任不要 | **直通**: Security Hub + Health ルール → SNS 東京 → Chatbot / Lambda。通知経路と調査 Lambda が管理アカウントに載る |
| 管理 = 集約 | `us-east-1`（リンク） | このリージョンでも委任管理者の指定が必要。finding は東京へ**集約** | 同上（リージョンごと） | グローバルサービス + `us-east-1` 発 | **直通**: Health ルールのみ → SNS us-east-1 |
| メンバー | 各 | 既存アカウントは**リージョンごとに手動で有効化・標準購読**（ローカル構成の自動有効化は新規アカウントのみ） | 自動有効化 `ALL` なら既存も対象。**統合 → 委任** | 発生元 | 置かない |

ケース 1 との差: 設定ポリシーが無い（ドリフトを自分で検知）、委任がリージョンごと、通知経路を置くアカウントに SCP が効かない。Health だけは手間が減る。

## ケース 3 — 1 メンバーアカウント（委任なし）

| アカウント | リージョン | Security Hub | GuardDuty / Inspector | AWS Health | 通知経路 |
|---|---|---|---|---|---|
| 当アカウント | `ap-northeast-1`（ホーム） | FSBP を有効化。リンクリージョンからの**集約**を受ける。グローバルリソースのコントロール（IAM.*）はここだけで評価し他では無効化 | 全保護機能。**統合**、ネイティブルールなし | **直通**ルール（detail-type 2 種） | **直通**: Security Hub ルール（GuardDuty 全重要度、コントロール HIGH+）+ Health ルール → SNS 東京 → Chatbot / Lambda。全ターゲットに DLQ |
| 当アカウント | `us-east-1`（リンク） | CloudFront / IAM などの finding は東京へ**集約**。ルールなし | 基礎データソースのみ。**統合** | **直通**ルール: グローバルサービス + `us-east-1` + `us-west-2` バックアップ | **直通**: Health ルールのみ → SNS us-east-1 → Chatbot / Lambda |
| 当アカウント | 他リージョン（ワークロード無し） | GuardDuty を動かす全リージョンをリンク（各リージョンの module を書いたうえで `ALL_REGIONS`。example は 3 リージョン）して finding を通知対象にし、グローバルリソース系コントロールを無効化して重複を消す。使わないなら Security Hub を無効化 | Detector は全リージョンに残す（不正利用はどこでも起きる）、ワークロード保護は OFF。Inspector は OFF | 稀。任意で `us-west-2` に 1 本置けば全リージョンのアカウント固有イベントを受けられる | 置かない（任意で `us-west-2` の Health ルール） |

原則: GuardDuty を有効にしているリージョンの集合とリンクリージョンの集合を一致させる。リンクしていないリージョンの finding は通知されない。

---

## 全ケース共通のルール

1. **失敗の発生ごとに 1 回だけ通知する。** `Workflow.Status = NEW` / `RecordState = ACTIVE` で絞り、ルールのターゲットを「SNS に publish してから `NOTIFIED` にする」小さな Lambda にする（SNS と Lambda を独立ターゲットにすると順序が保証されない）。受容したリスクは Security Hub で `SUPPRESSED` にし、EventBridge パターンには書かない。
2. **グローバルリソースのコントロールは 1 リージョンだけ。** IAM.* などをホーム以外で無効化しないと、同じアカウントレベルの finding が全リージョンで出る。
3. **EventBridge ターゲットに DLQ。** 無いと再試行後に破棄され、`FailedInvocations` メトリクスしか残らない。
4. **Chatbot は最小権限。** Chatbot IAM ガイドの通知用権限を使い（`ReadOnlyAccess` は過大）、`guardrail_policy_arns` を明示する（既定は AdministratorAccess）。
5. **SNS トピックはルールを置くリージョンごとに。** EventBridge は同リージョンのトピックにしか発行できない。購読者（Chatbot、Lambda）はクロスリージョン購読できるが、Lambda 購読の DLQ はトピック側リージョンに置く。
6. **すべて Terraform で管理する。** 手動で有効化されたリージョンも取り込む。provider alias はリージョンごと、module ブロックもリージョンごとに明示する。

---

## Terraform examples

`examples/security-notification-topology/` に共通 module とケースごとの root がある（ケース 1 は `management/` と `security/` の 2 root）。全 root が `terraform validate` を通している。ケース 3 は本番構成の写し、ケース 1・2 は実組織には未適用。`securityhub-home` module には finding を `NOTIFIED` にする Lambda が含まれ、グローバルリソース系コントロールはケース 2・3 では `securityhub-region` が、ケース 1 では中央設定がホーム以外で無効化する。

```bash
cd examples/security-notification-topology/case3-single-member
terraform init -backend=false
terraform validate
```

## 参考

- [Security Hub リージョン集約](https://docs.aws.amazon.com/securityhub/latest/userguide/finding-aggregation.html) · [中央設定](https://docs.aws.amazon.com/securityhub/latest/userguide/central-configuration-intro.html) · [Organizations 連携](https://docs.aws.amazon.com/securityhub/latest/userguide/designate-orgs-admin-account.html) · [EventBridge イベント種別](https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-cwe-integration-types.html) · [Workflow ステータス](https://docs.aws.amazon.com/securityhub/latest/userguide/finding-workflow-status.html) · [サービス統合](https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-internal-providers.html)
- [GuardDuty と Organizations](https://docs.aws.amazon.com/guardduty/latest/ug/guardduty_organizations.html) · [GuardDuty → Security Hub](https://docs.aws.amazon.com/guardduty/latest/ug/securityhub-integration.html)
- [Inspector の委任管理者](https://docs.aws.amazon.com/inspector/latest/user/designating-admin.html)
- [AWS Health のリージョン配信](https://docs.aws.amazon.com/health/latest/ug/choosing-a-region.html) · [イベントスキーマ](https://docs.aws.amazon.com/health/latest/ug/aws-health-events-eventbridge-schema.html) · [組織ビュー](https://docs.aws.amazon.com/health/latest/ug/aggregating-health-events.html) · [有効化](https://docs.aws.amazon.com/health/latest/ug/enable-organizational-view.html)
- [SNS クロスリージョン配信](https://docs.aws.amazon.com/sns/latest/dg/sns-cross-region-delivery.html) · [SNS デッドレターキュー](https://docs.aws.amazon.com/sns/latest/dg/sns-dead-letter-queues.html)
- [管理アカウントのベストプラクティス](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_best-practices_mgmt-acct.html) · [AWS SRA: Security Tooling account](https://docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/security-tooling.html)
