#tfsec:ignore:aws-ecr-enforce-immutable-repository -- accepted 2026-07-04 in D8, BEFORE this scanner ever ran: mutable :stable + immutable :sha tags is the assessment's deliberate trade-off; production path (IMMUTABLE + TF-driven tags) documented in D8 and walked through post-Phase-3
#tfsec:ignore:aws-ecr-repository-customer-key -- accepted 2026-07-07: AWS-managed encryption at rest suffices for public upstream images; CMK adds cost/complexity with no confidentiality gain (the images are public)
resource "aws_ecr_repository" "services" {
  for_each = toset(var.ecr_repositories)

  name = "${var.ecr_namespace}/${each.value}"

  image_scanning_configuration {
    scan_on_push = true
  }

  image_tag_mutability = "MUTABLE"
}

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
