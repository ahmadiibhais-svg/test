output "tf_state_bucket" {
  description = "S3 bucket for the main root's remote state (goes in its backend block)."
  value       = aws_s3_bucket.tf_state.bucket
}

output "ecr_repository_urls" {
  description = "Map of service name -> ECR repository URL (used by the pipeline and task definitions)."
  value       = { for name, repo in aws_ecr_repository.services : name => repo.repository_url }
}
