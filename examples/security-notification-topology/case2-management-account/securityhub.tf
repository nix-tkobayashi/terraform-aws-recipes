# The management account designates ITSELF as Security Hub delegated
# administrator. This is allowed only with local configuration (central
# configuration refuses the management account) and AWS recommends a separate
# account instead. Security Hub must be enabled here manually / by this root;
# it is never auto-enabled for the management account.

module "securityhub_home" {
  source = "../modules/securityhub-region"
}

module "securityhub_us_east_1" {
  source            = "../modules/securityhub-region"
  disabled_controls = var.global_resource_controls
  providers         = { aws = aws.us_east_1 }
}

# Delegated administrator is regional: designate in every region.
resource "aws_securityhub_organization_admin_account" "home" {
  admin_account_id = data.aws_caller_identity.current.account_id
  depends_on       = [module.securityhub_home]
}

resource "aws_securityhub_organization_admin_account" "us_east_1" {
  provider         = aws.us_east_1
  admin_account_id = data.aws_caller_identity.current.account_id
  depends_on       = [module.securityhub_us_east_1]
}

# Local configuration: auto-enable applies to NEW member accounts in this region
# only. Existing members must be enabled and subscribed per region by hand.
resource "aws_securityhub_organization_configuration" "home" {
  auto_enable           = true
  auto_enable_standards = "DEFAULT"
  depends_on            = [aws_securityhub_organization_admin_account.home]
}

resource "aws_securityhub_organization_configuration" "us_east_1" {
  provider              = aws.us_east_1
  auto_enable           = true
  auto_enable_standards = "DEFAULT"
  depends_on            = [aws_securityhub_organization_admin_account.us_east_1]
}

module "securityhub_rules" {
  source = "../modules/securityhub-home"

  service_name   = var.service_name
  environment    = var.environment
  linking_mode   = "SPECIFIED_REGIONS"
  linked_regions = var.linked_regions
  sns_topic_arn  = module.topic_home.topic_arn
  dlq_arn        = module.topic_home.dlq_arn

  depends_on = [module.securityhub_home, module.securityhub_us_east_1]
}
