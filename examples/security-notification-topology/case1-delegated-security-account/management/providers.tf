# Management account only. Delegated administrators are regional for GuardDuty
# and Inspector, so one alias per region. Assume a dedicated role in the
# management account; do not chain through another account.
provider "aws" {
  region = var.home_region
  assume_role { role_arn = var.management_role_arn }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  assume_role { role_arn = var.management_role_arn }
}
