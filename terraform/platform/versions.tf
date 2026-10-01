terraform {
  required_version = "~> 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.67"
    }
  }

  cloud {
    organization = "FlamaCorp"
    workspaces {
      name = "aws-platform"
    }
  }
}
