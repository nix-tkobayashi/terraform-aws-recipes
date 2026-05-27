# terraform-aws-recipes

AWS 環境における Terraform 構築レシピ集です。

[English version](README.md)

## Recipes

| レシピ | カテゴリ | 概要 |
|---|---|---|
| [GuardDuty 全リージョン一元管理](guardduty-multiregion-setup.ja.md) | Security | GuardDuty を全リージョンで有効化し、単一 Terraform ワークスペースから管理。AWS Chatbot 経由の Slack 通知付き（MEDIUM+ Finding） |

## Scripts

| スクリプト | カテゴリ | 概要 |
|---|---|---|
| [Default VPC 一括削除](scripts/delete-default-vpcs.ja.md) | Security | 全リージョンの未使用 Default VPC を安全に削除。ドライラン対応・多層安全チェック付き |

## 使い方

各レシピは AI アシスタントへの構築プロンプトとして使えます。前提条件のパラメータを埋めてプロンプトとして渡すことで、Terraform コードを生成できます。

## License

MIT
