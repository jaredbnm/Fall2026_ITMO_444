terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Every resource Terraform creates gets this tag, so you can find (and prove you removed) all of them.
  default_tags {
    tags = {
      Project = "itmo-444-544-lab07"
    }
  }
}