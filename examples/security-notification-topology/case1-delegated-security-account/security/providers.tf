# Security tooling account (delegated administrator). One alias per region.
provider "aws" {
  region = var.home_region
  assume_role { role_arn = var.security_role_arn }
  default_tags { tags = local.common_tags }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  assume_role { role_arn = var.security_role_arn }
  default_tags { tags = local.common_tags }
}

provider "aws" {
  alias  = "chatbot"
  region = "us-east-2"
  assume_role { role_arn = var.security_role_arn }
  default_tags { tags = local.common_tags }
}
