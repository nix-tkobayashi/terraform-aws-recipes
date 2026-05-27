# Default VPC 一括削除スクリプト

[English version](delete-default-vpcs.md)

## 概要

全 AWS リージョンの未使用 Default VPC を安全に削除するシェルスクリプトです。

Default VPC は AWS アカウント作成時に全リージョンへ自動生成されます。本番環境では使用されないケースが多く、削除することで攻撃対象面の削減やセキュリティ監査要件（CIS AWS Foundations Benchmark 等）への準拠が可能です。

## 処理フロー

1. **認証確認** — AWS 認証情報を検証し、アカウント ID・ロールを表示
2. **Default VPC 検出** — リージョンごとに `is-default` フィルタで特定
3. **利用状況チェック** — 6 種類のリソース（ENI, EC2, RDS, ELB, NAT Gateway, VPC Endpoint）を確認。1 つでもあればスキップ
4. **API エラー処理** — API 失敗時は「確認不能」として削除をスキップ（エラーを 0 件扱いしない）
5. **IsDefault 再確認** — 削除直前に `IsDefault=True` を再検証
6. **順序付き削除** — サブネット → Internet Gateway（デタッチ＋削除） → VPC
7. **終了コード** — 失敗リージョンがあれば非ゼロで終了

## 前提条件

- AWS CLI v2
- jq
- EC2/RDS/ELB の読み取り・書き込み権限を持つ AWS 認証情報

## 使い方

```bash
# 認証情報をセット
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."  # 一時認証情報の場合

# ドライラン（確認のみ、削除しない）
./scripts/delete-default-vpcs.sh

# 実際に削除
./scripts/delete-default-vpcs.sh --execute
```

## 安全設計

| 懸念事項 | 対策 |
|---|---|
| Default VPC 以外を誤って削除 | `is-default=true` のみ対象。削除直前に `IsDefault` を再確認 |
| リソースが稼働中の VPC を削除 | 6 種類のリソースを事前チェック。ENI 数だけでも大半の依存を検出可能 |
| API エラーが「リソースなし」扱いに | API 失敗は `-1` を返し、そのリージョンをスキップ |
| 途中失敗で中途半端な状態に | 各ステップでエラーチェック。失敗時はスキップしてカウント |
| 誤って破壊的操作を実行 | デフォルトはドライラン。`--execute` フラグが必須 |
