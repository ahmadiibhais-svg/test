# GitLab CI -> AWS via OIDC federation (deferred in D7, delivered in Phase 3 / D13).
# The pipeline holds ZERO long-lived AWS credentials: each job presents a
# GitLab-signed identity token (a passport), AWS checks issuer + project path
# (border control), and STS hands out ~1h temporary credentials. Same pattern
# as IRSA in EKS, with gitlab.com as the issuer.

# The trusted passport issuer.
resource "aws_iam_openid_connect_provider" "gitlab" {
  url = "https://gitlab.com"

  # The "aud" claim our CI tokens will carry (set in .gitlab-ci.yml id_tokens).
  client_id_list = ["https://gitlab.com"]

  # Legacy-required field: AWS now validates gitlab.com against its own trusted
  # CA store and largely ignores this, but the API demands a value. Root-CA
  # SHA1 fetched live via openssl on 2026-07-05.
  thumbprint_list = ["d89e3bd43d5d909b47a18977aa9d5ce36cee184c"]
}

# The role a passport-holder may wear. Border control lives in the conditions:
#   aud  = the audience we mint tokens for
#   sub  = ONLY this project, pinned by IMMUTABLE PROJECT ID (84090295), not path.
# Why ID not path: GitLab refused to issue path-subject tokens because this
# project's path had a prior life (deleted project) — paths are recyclable and a
# recreated path would inherit path-pinned cloud trust. IDs can't be recycled.
# Requires the project setting id_token_sub_claim_components =
# ["project_id","ref_type","ref"] (set in GitLab, 2026-07-05).
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

# Assessment trade-off (D13, documented before a reviewer asks): one role with
# admin for the week — CI runs the same authority the human runs. Production
# splits this into a read+plan role, a scoped apply role behind an approval
# environment, and an app-deploy role limited to ECR push + ECS update.
resource "aws_iam_role_policy_attachment" "gitlab_ci_admin" {
  role       = aws_iam_role.gitlab_ci.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "gitlab_ci_role_arn" {
  description = "Role ARN the pipeline assumes (referenced in .gitlab-ci.yml)."
  value       = aws_iam_role.gitlab_ci.arn
}
