terraform {
    required_providers {
        aws = {
            source = "hashicorp/aws"
            version = "~> 5.0"
        }
    }
}

provider "aws" {
    region = "us-east-2"
}

resource "aws_dynamodb_table" "demo" {
    name = "itmo-444-544-terraform-demo"
    billing_mode = "PAY_PER_REQUEST"
    hash_key = "name"

    tags = { Purpose = "first-taste" }

    attribute {
        name = "name"
        type = "S"
    }
}

output "table_arn" {
    value = aws_dynamodb_table.demo.arn
}