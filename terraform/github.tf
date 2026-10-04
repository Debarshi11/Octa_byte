# ---------------------------------------------------------------------------
# GitHub Actions -> AWS authentication.
#
# OIDC federation instead of long-lived access keys: GitHub exchanges a signed
# token for temporary credentials scoped to this role, so there is no
# `AWS_ACCESS_KEY_ID` in repository secrets to rotate, leak or forget to revoke.
#
# The trust policy is scoped to a single repository and any ref in it. Narrow
# `sub` to `repo:<org>/<repo>:ref:refs/heads/main` if you want only `main` to
# be able to deploy.
# ---------------------------------------------------------------------------

variable "github_repository" {
  description = "GitHub repository allowed to assume the deploy role, in `owner/name` form."
  type        = string
  default     = "CHANGE_ME/notes-app"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]

  tags = { Name = "${local.name_prefix}-github-oidc" }
}

resource "aws_iam_role" "github_deploy" {
  name = "${local.name_prefix}-github-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:*"
        }
      }
    }]
  })

  tags = { Name = "${local.name_prefix}-github-deploy" }
}

# Terraform needs broad write access to manage this stack (VPC, ECS, RDS, IAM,
# CloudWatch, S3...). PowerUserAccess is the pragmatic happy-path choice and is
# deliberately called out in docs/CHALLENGES.md as a known trade-off: the real
# fix is a hand-written policy enumerating only the actions this stack uses.
#
# It deliberately does NOT include IAM full access (`iam:*`) beyond what
# PowerUserAccess allows, and the role can only be assumed from this repo.
resource "aws_iam_role_policy_attachment" "github_deploy" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

output "github_deploy_role_arn" {
  description = "Set this as the AWS_DEPLOY_ROLE_ARN repository variable in GitHub Actions."
  value       = aws_iam_role.github_deploy.arn
}
