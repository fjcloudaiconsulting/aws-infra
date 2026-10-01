terraform {
  required_version = "~> 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.67"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.5"
    }
  }

  cloud {
    organization = "FlamaCorp"
    workspaces {
      name = "aws-platform"
    }
  }
}
