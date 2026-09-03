# Delegated administrator and organization defaults are regional.
resource "aws_inspector2_delegated_admin_account" "home" {
  account_id = data.aws_caller_identity.current.account_id
}

resource "aws_inspector2_delegated_admin_account" "us_east_1" {
  provider   = aws.us_east_1
  account_id = data.aws_caller_identity.current.account_id
}

module "inspector_home" {
  source              = "../modules/inspector-region"
  manage_organization = true
  member_account_ids  = var.member_account_ids
  depends_on          = [aws_inspector2_delegated_admin_account.home]
}

module "inspector_us_east_1" {
  source              = "../modules/inspector-region"
  manage_organization = true
  member_account_ids  = var.member_account_ids
  providers           = { aws = aws.us_east_1 }
  depends_on          = [aws_inspector2_delegated_admin_account.us_east_1]
}
