# Organization defaults are regional; existing members need explicit enablement.
module "inspector_home" {
  source              = "../../modules/inspector-region"
  manage_organization = true
  member_account_ids  = var.member_account_ids
}

module "inspector_us_east_1" {
  source              = "../../modules/inspector-region"
  manage_organization = true
  member_account_ids  = var.member_account_ids
  providers           = { aws = aws.us_east_1 }
}
