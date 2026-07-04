# One ECR repository per service (13 — see var.ecr_repositories / SERVICES.md).
#
# for_each over a set is Terraform's Helm-`range` analog: one resource instance per
# name, individually addressable as aws_ecr_repository.services["front-end"].
resource "aws_ecr_repository" "services" {
  for_each = toset(var.ecr_repositories)

  name = "${var.ecr_namespace}/${each.value}"

  # ECR's built-in vulnerability scan on every push — the first scanning layer
  # (pipeline Trivy is the second). Findings surface per-image in the console.
  image_scanning_configuration {
    scan_on_push = true
  }

  # MUTABLE because the pipeline re-points a `stable` tag on each deploy.
  # Documented trade-off: immutable tags driven through Terraform are the stricter
  # production pattern (see docs, Phase 3).
  image_tag_mutability = "MUTABLE"
}

# Re-pushing tags leaves untagged layer sets behind, and they still bill storage
# ($0.10/GB-month). Expire them automatically after 7 days.
resource "aws_ecr_lifecycle_policy" "expire_untagged" {
  for_each = aws_ecr_repository.services

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
