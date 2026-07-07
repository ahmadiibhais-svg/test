# S3 bucket that will hold Terraform state for the main root.
#
# Chicken-and-egg note: the bucket that stores state cannot store the state of its
# own creation — so THIS root keeps local state. Acceptable because bootstrap is
# tiny, applied once, and never part of the nightly destroy (DECISIONS.md D7).

data "aws_caller_identity" "current" {}

#tfsec:ignore:aws-s3-enable-bucket-logging -- accepted 2026-07-07: access logging for a single-user state bucket adds a second bucket + lifecycle for audit data nobody reads at this scale; CloudTrail covers the API-level story
resource "aws_s3_bucket" "tf_state" {
  # Bucket names are globally unique across ALL AWS accounts; suffixing the account
  # ID guarantees uniqueness (account IDs are not secret — they appear in every ARN).
  bucket = "avertra-sockshop-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    # Hard refusal to destroy the resource that holds every other stack's memory.
    prevent_destroy = true
  }
}

# Versioning = undo history for state. A corrupted or mis-written state file can be
# rolled back to any prior version — insurance that costs kilobytes.
resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# State files contain resource attributes (endpoints, ARNs, generated values) —
# encrypt at rest with the free S3-managed key (SSE-S3 / AES256).
#tfsec:ignore:aws-s3-encryption-customer-key -- accepted 2026-07-07: SSE-S3 encrypts at rest for free; a CMK protects against an attacker who ALREADY has s3:GetObject in a single-user account — negligible marginal gain (D10 records the related state-secret trade-off)
resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Belt-and-braces: block every form of public access (ACL- and policy-based,
# present and future). State must never be publicly readable.
resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
