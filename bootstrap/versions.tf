# Terraform and provider version constraints.
terraform {
  # >= 1.10 gives the main root the native S3 state lockfile (`use_lockfile`),
  # so this project needs no DynamoDB lock table at all.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pin the major version (like pinning a Helm chart major): breaking changes
      # arrive in majors; "~> 6.0" means any 6.x, never 7.
      version = "~> 6.0"
    }
  }
}
