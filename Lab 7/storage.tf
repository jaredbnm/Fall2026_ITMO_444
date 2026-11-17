# The weather tier's cache and history. On-demand billing, items expire by themselves, and no backups.
resource "aws_dynamodb_table" "weather" {
  name         = "${var.name_prefix}-weather-lookups"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "zip"

  attribute {
    name = "zip"
    type = "S"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = false
  }
}

# The Gemini key lives in Parameter Store, never in a file. Terraform creates the empty slot, and
# you put the real key into it with the AWS CLI. ignore_changes stops Terraform from ever looking
# at or overwriting the value, which also keeps the key out of the Terraform state file.
resource "aws_ssm_parameter" "gemini" {
  name  = "/${var.name_prefix}/gemini-api-key"
  type  = "SecureString"
  value = "not-set-yet"

  lifecycle {
    ignore_changes = [value]
  }
}