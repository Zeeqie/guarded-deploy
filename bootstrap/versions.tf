# bootstrap/ creates the S3 bucket that infra/ stores its state in.
# It cannot store its own state in a bucket that does not exist yet, so it
# deliberately uses LOCAL state (terraform.tfstate, gitignored).
terraform {
  required_version = "~> 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.74.0"
    }
  }
}

provider "aws" {
  region = var.region

  # Every resource this config creates gets these tags (cost tracking + "who made this?").
  default_tags {
    tags = {
      Project   = "guarded-deploy"
      ManagedBy = "terraform"
    }
  }
}
