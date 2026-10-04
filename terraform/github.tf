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
  default     = "Debarshi11/Octa_byte"
}

variable "github_repository_id" {
  description = "GitHub numeric repository ID - the `repository_id` OIDC claim. From: gh api repos/<owner>/<name> -q .id"
  type        = string
  default     = "1404454869"
}

variable "github_repository_owner_id" {
  description = "GitHub numeric owner ID - the `repository_owner_id` OIDC claim. From: gh api users/<owner> -q .id"
  type        = string
  default     = "77461376"
}

locals {
  github_owner = split("/", var.github_repository)[0]
  github_repo  = split("/", var.github_repository)[1]
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]

  tags = { Name = "${local.name_prefix}-github-oidc" }
}

resource "aws_iam_role" "github_deploy" {
  name = "${local.name_prefix}-github-deploy"

  # GitHub changed the OIDC `sub` claim format. It used to be
  #     repo:OWNER/REPO:ref:refs/heads/main
  # and is now
  #     repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/main
  # with `:environment:<name>` in place of `:ref:...` for jobs bound to a GitHub
  # Environment. Both shapes are matched so this survives the transition.
  #
  # The actual pinning is the numeric `repository_id` and `repository_owner_id`
  # conditions: those are stable and cannot be spoofed by renaming or
  # transferring the repository, whereas a name-based `sub` pattern can.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud"                 = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:repository_id"       = var.github_repository_id
          "token.actions.githubusercontent.com:repository_owner_id" = var.github_repository_owner_id
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            "repo:${local.github_owner}@${var.github_repository_owner_id}/${local.github_repo}@${var.github_repository_id}:*",
            "repo:${var.github_repository}:*",
          ]
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

# PowerUserAccess is `Allow` with `NotAction` on iam:/organizations:/account:,
# so it grants every service EXCEPT IAM. Terraform has to manage this stack's
# five roles and its OIDC provider, so those calls come back 403
# ("not authorized to perform iam:GetRole ... because no identity-based policy
# allows the action").
#
# Scoped by resource rather than by blanket `iam:*`: the role can only touch
# roles named notes-<environment>-* and this one OIDC provider. That is the
# difference between "can administer the stack" and "can administer IAM".
resource "aws_iam_role_policy" "github_deploy_stack_iam" {
  name = "manage-stack-iam-resources"
  role = aws_iam_role.github_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageTheRolesThisStackOwns"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:UpdateRole",
          "iam:UpdateRoleDescription",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListRoleTags",
          "iam:GetRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PassRole",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-*"
      },
      {
        Sid    = "ManageThisOIDCProvider"
        Effect = "Allow"
        Action = [
          "iam:GetOpenIDConnectProvider",
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProviderThumbprint",
          "iam:AddClientIDToOpenIDConnectProvider",
          "iam:RemoveClientIDFromOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider",
          "iam:UntagOpenIDConnectProvider",
          "iam:ListOpenIDConnectProviderTags",
        ]
        Resource = aws_iam_openid_connect_provider.github.arn
      },
      {
        Sid      = "ReadAWSManagedPolicyMetadata"
        Effect   = "Allow"
        Action   = ["iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions"]
        Resource = "arn:aws:iam::aws:policy/*"
      },
      {
        # ECS, Application Auto Scaling and AWS Budgets all need their
        # service-linked roles to exist first.
        Sid      = "AllowServiceLinkedRoles"
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "arn:aws:iam::*:role/aws-service-role/*"
        Condition = {
          StringEquals = {
            "iam:AWSService" = [
              "ecs.amazonaws.com",
              "ecs.application-autoscaling.amazonaws.com",
              "budgets.amazonaws.com",
            ]
          }
        }
      },
    ]
  })
}

output "github_deploy_role_arn" {
  description = "Set this as the AWS_DEPLOY_ROLE_ARN repository variable in GitHub Actions."
  value       = aws_iam_role.github_deploy.arn
}
