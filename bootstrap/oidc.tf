resource "aws_iam_openid_connect_provider" "gitlab" {
  url = "https://gitlab.com"

  client_id_list = ["https://gitlab.com"]

  thumbprint_list = ["d89e3bd43d5d909b47a18977aa9d5ce36cee184c"]
}

resource "aws_iam_role" "gitlab_ci" {
  name = "avertra-sockshop-gitlab-ci"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRoleWithWebIdentity"
      Principal = {
        Federated = aws_iam_openid_connect_provider.gitlab.arn
      }
      Condition = {
        StringEquals = {
          "gitlab.com:aud" = "https://gitlab.com"
        }
        StringLike = {
          "gitlab.com:sub" = "project_id:84090295:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "gitlab_ci_admin" {
  role       = aws_iam_role.gitlab_ci.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "gitlab_ci_role_arn" {
  description = "Role ARN the pipeline assumes (referenced in .gitlab-ci.yml)."
  value       = aws_iam_role.gitlab_ci.arn
}
