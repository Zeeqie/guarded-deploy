terraform {
  required_version = "~> 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.74.0"
    }
  }

  # Partial config: `bucket` is passed at init so the account ID stays out of the code:
  #   terraform init -backend-config="bucket=$(terraform -chdir=../bootstrap output -raw state_bucket_name)"
  backend "s3" {
    key          = "infra/terraform.tfstate"
    region       = "ap-southeast-1"
    encrypt      = true
    use_lockfile = true # S3-native lock object (.tflock); no DynamoDB lock table needed
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "guarded-deploy"
      ManagedBy = "terraform"
    }
  }
}
