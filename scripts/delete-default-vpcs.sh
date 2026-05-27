#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# delete-default-vpcs.sh
#
# 全リージョンの Default VPC を安全に削除するスクリプト
#
# 使い方:
#   # ドライラン（削除せず確認のみ）
#   ./scripts/delete-default-vpcs.sh
#
#   # 実際に削除
#   ./scripts/delete-default-vpcs.sh --execute
#
# 前提:
#   - AWS 認証情報が環境変数にセット済みであること
#   - aws cli v2 がインストール済みであること
#   - jq がインストール済みであること
###############################################################################

EXECUTE=false
if [[ "${1:-}" == "--execute" ]]; then
  EXECUTE=true
fi

REGIONS=(
  ap-northeast-1 ap-northeast-2 ap-northeast-3
  ap-south-1 ap-southeast-1 ap-southeast-2
  ca-central-1
  eu-central-1 eu-north-1 eu-west-1 eu-west-2 eu-west-3
  sa-east-1
  us-east-1 us-east-2 us-west-1 us-west-2
)

SUCCESS_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0
NO_VPC_COUNT=0

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*"; }
ok()   { log "OK    $*"; }

divider() { echo "----------------------------------------------------------------------"; }

###############################################################################
# 安全な API 呼び出しラッパー
# API エラー時は空文字ではなく "ERROR" を返し、呼び出し元で検知できるようにする
###############################################################################
safe_query() {
  local result
  if result=$("$@" 2>&1); then
    echo "$result"
  else
    echo "ERROR: $result" >&2
    echo "ERROR"
  fi
}

###############################################################################
# 利用状況チェック: 各リソースの件数を安全に取得
# API エラー時は -1 を返す（0 ではなく失敗として扱う）
###############################################################################
safe_count() {
  local val
  val=$(safe_query "$@")
  if [[ "$val" == "ERROR" ]]; then
    echo "-1"
  else
    echo "${val:-0}"
  fi
}

###############################################################################
# 利用状況を総合チェック
# 戻り値: 0=未使用（削除可）, 1=使用中, 2=チェック不能
###############################################################################
check_vpc_in_use() {
  local region=$1 vpc_id=$2
  local in_use=false
  local check_failed=false

  local enis instances rds elb nat endpoints

  enis=$(safe_count aws ec2 describe-network-interfaces \
    --region "$region" \
    --filters "Name=vpc-id,Values=$vpc_id" \
    --query 'NetworkInterfaces | length(@)' \
    --output text)

  instances=$(safe_count aws ec2 describe-instances \
    --region "$region" \
    --filters "Name=vpc-id,Values=$vpc_id" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances | length(@)' \
    --output text)

  rds=$(safe_count aws rds describe-db-instances \
    --region "$region" \
    --query "DBInstances[?DBSubnetGroup.VpcId=='${vpc_id}'] | length(@)" \
    --output text)

  elb=$(safe_count aws elbv2 describe-load-balancers \
    --region "$region" \
    --query "LoadBalancers[?VpcId=='${vpc_id}'] | length(@)" \
    --output text)

  nat=$(safe_count aws ec2 describe-nat-gateways \
    --region "$region" \
    --filter "Name=vpc-id,Values=$vpc_id" "Name=state,Values=available" \
    --query 'NatGateways | length(@)' \
    --output text)

  endpoints=$(safe_count aws ec2 describe-vpc-endpoints \
    --region "$region" \
    --filters "Name=vpc-id,Values=$vpc_id" \
    --query 'VpcEndpoints | length(@)' \
    --output text)

  info "  ENI=$enis  EC2=$instances  RDS=$rds  ELB=$elb  NAT=$nat  Endpoint=$endpoints"

  for label_val in "ENI:$enis" "EC2:$instances" "RDS:$rds" "ELB:$elb" "NAT:$nat" "Endpoint:$endpoints"; do
    local label="${label_val%%:*}"
    local val="${label_val#*:}"
    if [[ "$val" == "-1" ]]; then
      err "  ${label} のチェックで API エラー発生 — 安全のため削除不可"
      check_failed=true
    elif [[ "$val" -gt 0 ]]; then
      warn "  ${label} が ${val} 個存在"
      in_use=true
    fi
  done

  $check_failed && return 2
  $in_use && return 1
  return 0
}

###############################################################################
# 削除直前の IsDefault 再確認
###############################################################################
verify_is_default() {
  local region=$1 vpc_id=$2
  local is_default
  is_default=$(aws ec2 describe-vpcs \
    --region "$region" \
    --vpc-ids "$vpc_id" \
    --query 'Vpcs[0].IsDefault' \
    --output text 2>&1) || {
    err "  VPC 情報の取得に失敗: $is_default"
    return 1
  }
  if [[ "$is_default" != "True" ]]; then
    err "  $vpc_id は Default VPC ではありません (IsDefault=$is_default) — 削除中止"
    return 1
  fi
  return 0
}

###############################################################################
# サブネット削除
###############################################################################
delete_subnets() {
  local region=$1 vpc_id=$2
  local subnet_ids
  subnet_ids=$(aws ec2 describe-subnets \
    --region "$region" \
    --filters "Name=vpc-id,Values=$vpc_id" \
    --query 'Subnets[].SubnetId' \
    --output text 2>&1) || {
    err "  サブネット一覧の取得に失敗: $subnet_ids"
    return 1
  }

  for subnet_id in $subnet_ids; do
    info "  サブネット削除: $subnet_id"
    if ! aws ec2 delete-subnet --region "$region" --subnet-id "$subnet_id" 2>&1; then
      err "  サブネット削除失敗: $subnet_id"
      return 1
    fi
  done
}

###############################################################################
# IGW デタッチ＆削除
###############################################################################
delete_igw() {
  local region=$1 vpc_id=$2
  local igw_id
  igw_id=$(aws ec2 describe-internet-gateways \
    --region "$region" \
    --filters "Name=attachment.vpc-id,Values=$vpc_id" \
    --query 'InternetGateways[0].InternetGatewayId' \
    --output text 2>&1) || {
    err "  IGW 一覧の取得に失敗: $igw_id"
    return 1
  }

  if [[ -z "$igw_id" || "$igw_id" == "None" ]]; then
    info "  IGW なし — スキップ"
    return 0
  fi

  info "  IGW デタッチ: $igw_id <- $vpc_id"
  if ! aws ec2 detach-internet-gateway --region "$region" --internet-gateway-id "$igw_id" --vpc-id "$vpc_id" 2>&1; then
    err "  IGW デタッチ失敗: $igw_id"
    return 1
  fi

  info "  IGW 削除: $igw_id"
  if ! aws ec2 delete-internet-gateway --region "$region" --internet-gateway-id "$igw_id" 2>&1; then
    err "  IGW 削除失敗: $igw_id"
    return 1
  fi
}

###############################################################################
# VPC 削除
###############################################################################
delete_vpc() {
  local region=$1 vpc_id=$2

  info "  VPC 削除: $vpc_id"
  if ! aws ec2 delete-vpc --region "$region" --vpc-id "$vpc_id" 2>&1; then
    err "  VPC 削除失敗: $vpc_id (依存リソースが残っている可能性)"
    return 1
  fi
}

###############################################################################
# メイン処理
###############################################################################
echo ""
echo "============================================================"
if $EXECUTE; then
  echo "  Default VPC 削除 [EXECUTE モード]"
else
  echo "  Default VPC 削除 [DRY-RUN モード]"
  echo "  ※ 実際に削除するには --execute を付けて実行"
fi
echo "============================================================"
echo ""

# 認証確認
identity=$(aws sts get-caller-identity --region ap-northeast-1 --output json 2>&1) || {
  err "AWS 認証に失敗しました。認証情報を確認してください。"
  echo "$identity"
  exit 1
}
account_id=$(echo "$identity" | jq -r '.Account')
arn=$(echo "$identity" | jq -r '.Arn')
info "Account: $account_id"
info "Role:    $arn"
echo ""

for region in "${REGIONS[@]}"; do
  divider
  info "[$region] 処理開始"

  # Default VPC 取得
  vpc_id=$(aws ec2 describe-vpcs \
    --region "$region" \
    --filters "Name=is-default,Values=true" \
    --query 'Vpcs[0].VpcId' \
    --output text 2>&1) || {
    err "[$region] VPC 一覧の取得に失敗 — スキップ"
    ((FAIL_COUNT++))
    continue
  }

  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    info "[$region] Default VPC なし — スキップ"
    ((NO_VPC_COUNT++))
    continue
  fi

  info "[$region] Default VPC: $vpc_id"

  # 利用状況チェック
  check_vpc_in_use "$region" "$vpc_id"
  check_result=$?

  if [[ $check_result -eq 2 ]]; then
    err "[$region] API エラーにより安全確認不能 — スキップ"
    ((FAIL_COUNT++))
    continue
  elif [[ $check_result -eq 1 ]]; then
    warn "[$region] リソースが検出されたため削除をスキップ"
    ((SKIP_COUNT++))
    continue
  fi

  ok "[$region] 利用中リソースなし — 削除可能"

  if ! $EXECUTE; then
    info "[$region] DRY-RUN: 削除をスキップ"
    continue
  fi

  # 削除直前に IsDefault を再確認
  if ! verify_is_default "$region" "$vpc_id"; then
    err "[$region] IsDefault 再確認に失敗 — スキップ"
    ((FAIL_COUNT++))
    continue
  fi

  # 削除実行: サブネット → IGW → VPC
  info "[$region] 削除開始..."

  if ! delete_subnets "$region" "$vpc_id"; then
    err "[$region] サブネット削除で失敗 — この VPC をスキップ"
    ((FAIL_COUNT++))
    continue
  fi

  if ! delete_igw "$region" "$vpc_id"; then
    err "[$region] IGW 削除で失敗 — この VPC をスキップ"
    ((FAIL_COUNT++))
    continue
  fi

  if ! delete_vpc "$region" "$vpc_id"; then
    err "[$region] VPC 削除で失敗"
    ((FAIL_COUNT++))
    continue
  fi

  ok "[$region] Default VPC 削除完了"
  ((SUCCESS_COUNT++))
done

divider
echo ""
echo "============================================================"
echo "  結果サマリ"
echo "============================================================"
if $EXECUTE; then
  echo "  削除成功: $SUCCESS_COUNT リージョン"
  echo "  削除失敗: $FAIL_COUNT リージョン"
fi
echo "  スキップ (リソースあり): $SKIP_COUNT リージョン"
echo "  VPC なし: $NO_VPC_COUNT リージョン"
echo "============================================================"
echo ""

if [[ $FAIL_COUNT -gt 0 ]]; then
  exit 1
fi
