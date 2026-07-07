data "aws_caller_identity" "current" {}

#tfsec:ignore:aws-s3-enable-bucket-logging -- accepted 2026-07-07: access logging for a single-user state bucket adds a second bucket + lifecycle for audit data nobody reads at this scale; CloudTrail covers the API-level story
resource "aws_s3_bucket" "tf_state" {
  bucket = "avertra-sockshop-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

#tfsec:ignore:aws-s3-encryption-customer-key -- accepted 2026-07-07: SSE-S3 encrypts at rest for free; a CMK protects against an attacker who ALREADY has s3:GetObject in a single-user account — negligible marginal gain (D10 records the related state-secret trade-off)
resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
