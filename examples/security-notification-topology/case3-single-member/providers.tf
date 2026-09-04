# One provider alias per region that hosts resources. Terraform cannot pass a
# provider to module instances created with for_each, so every region gets an
# explicit module block below (see README for adding the remaining regions).

provider "aws" {
  region = var.home_region
  default_tags {
    tags = local.common_tags
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = local.common_tags
  }
}

# us-west-2 receives account-specific Health events from every region as backup.
provider "aws" {
  alias  = "us_west_2"
  region = "us-west-2"
  default_tags {
    tags = local.common_tags
  }
}

# AWS Chatbot (Amazon Q Developer in chat applications) is a global service
# whose API is served from us-east-2.
provider "aws" {
  alias  = "chatbot"
  region = "us-east-2"
  default_tags {
    tags = local.common_tags
  }
}
