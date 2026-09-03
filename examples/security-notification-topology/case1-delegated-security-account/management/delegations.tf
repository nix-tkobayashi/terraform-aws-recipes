# --- Security Hub CSPM: one designation (central configuration propagates it to linked regions) ---
resource "aws_securityhub_organization_admin_account" "this" {
  admin_account_id = var.security_account_id
}

# --- GuardDuty: regional, same account everywhere ---
resource "aws_guardduty_organization_admin_account" "home" {
  admin_account_id = var.security_account_id
}

resource "aws_guardduty_organization_admin_account" "us_east_1" {
  provider         = aws.us_east_1
  admin_account_id = var.security_account_id
}

# --- Inspector: regional, same account everywhere ---
resource "aws_inspector2_delegated_admin_account" "home" {
  account_id = var.security_account_id
}

resource "aws_inspector2_delegated_admin_account" "us_east_1" {
  provider   = aws.us_east_1
  account_id = var.security_account_id
}

# --- AWS Health: organizational view must be enabled first (console, any support
# plan; CLI/API needs Business or higher; no Terraform resource). Then delegate
# the feed to the security account. Up to five delegated administrators.
resource "aws_organizations_delegated_administrator" "health" {
  account_id        = var.security_account_id
  service_principal = "health.amazonaws.com"
}
