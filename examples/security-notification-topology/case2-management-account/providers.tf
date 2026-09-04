# Run from the Organizations management account. One alias per region.
provider "aws" {
  region = var.home_region
  default_tags { tags = local.common_tags }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags { tags = local.common_tags }
}

provider "aws" {
  alias  = "chatbot"
  region = "us-east-2"
  default_tags { tags = local.common_tags }
}
