terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  # State is kept locally by default. For team use, switch to an S3 backend:
  # backend "s3" {
  #   bucket       = "my-terraform-state-bucket"
  #   key          = "spendwise/terraform.tfstate"
  #   region       = "us-east-1"
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}
