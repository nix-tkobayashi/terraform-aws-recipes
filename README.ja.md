# terraform-aws-recipes

AWS 環境における Terraform 構築レシピ集です。

[English version](README.md)

## Recipes

| レシピ | カテゴリ | 概要 |
|---|---|---|
| [GuardDuty 全リージョン一元管理](guardduty-multiregion-setup.ja.md) | Security | GuardDuty を全リージョンで有効化し、単一 Terraform ワークスペースから管理。AWS Chatbot 経由の Slack 通知付き（MEDIUM+ Finding） |
| [SecurityHub Finding Aggregator](securityhub-finding-aggregator.ja.md) | Security | SecurityHub のクロスリージョン Finding 集約で GuardDuty 通知パイプラインを簡素化。リージョン別 EventBridge 転送方式の代替 — 各リージョンの通知リソースが不要に |
| [AWS Health 通知 via EventBridge](health-notification-via-eventbridge.ja.md) | Operations | us-west-2 の EventBridge 1 ルールで全リージョンの AWS Health イベントを捕捉（2025年11月〜）。AI 分析 + 重要度別ダイジェストバッチング |

## ガイド

| ガイド | 説明 |
|---|---|
| [セキュリティ通知の配送トポロジー](security-notification-topology.ja.md) | Security Hub / GuardDuty / Inspector / Health の EventBridge ルールと SNS トピックを、どのアカウント・どのリージョンに置くか。3 つの構成（委任管理者 = セキュリティ集約アカウント、管理アカウント = 集約アカウント、1 メンバーアカウント）を「委任・集約・統合・直通」の 4 つの仕組みで説明する。[HTML のマトリクス](docs/security-notification-topology.html)付き。 |

## Examples

| Example | 説明 |
|---|---|
| [セキュリティ通知の配送トポロジー](examples/security-notification-topology/) | 上記 3 構成の参照実装。共通 module + ケースごとの root で、`terraform validate` を通している。 |

## 規約

| ガイド | 概要 |
|---|---|
| [命名規則](naming-conventions.ja.md) | AWS リソース名のパターンと Terraform 識別子のルール |
| [Terraform モジュール規約](terraform-conventions.ja.md) | モジュール構成と変数の使い分けガイドライン |

## Scripts

| スクリプト | カテゴリ | 概要 |
|---|---|---|
| [Default VPC 一括削除](scripts/delete-default-vpcs.ja.md) | Security | 全リージョンの未使用 Default VPC を安全に削除。ドライラン対応・多層安全チェック付き |

## 使い方

各レシピは AI アシスタントへの構築プロンプトとして使えます。前提条件のパラメータを埋めてプロンプトとして渡すことで、Terraform コードを生成できます。 ガイドはレシピ同士の組み合わせ方を説明し、Examples は `terraform validate` を通したデプロイ可能な参照コードです。

## License

MIT
