# ---------------- GitHub Actions -> AWS via OIDC (no stored keys) ----------------
# See docs/learning/oidc-trust-policy.md.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # thumbprint_list omitted: IAM validates this IdP against its trusted root CAs.
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    sid     = "GitHubMainBranchOnly"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      # Exact claim seen in CloudTrail for the failed first CD run (docs/incidents.md).
      values = ["repo:${var.github_oidc_subject_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name                 = "${var.name}-github-deploy"
  assume_role_policy   = data.aws_iam_policy_document.github_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_deploy" {
  # GetAuthorizationToken does not support resource-level permissions: AWS only accepts "*".
  # It only returns a registry login token; what can be pushed/pulled is limited below.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushPullThisRepo"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages", # "does tag <sha> already exist?" (tags are IMMUTABLE)
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  statement {
    sid = "DeployThisFunction"
    actions = [
      "lambda:UpdateFunctionCode",
      "lambda:PublishVersion",
      "lambda:GetFunction",
      "lambda:GetAlias",
      "lambda:UpdateAlias",
      "lambda:InvokeFunction",
      "lambda:ListVersionsByFunction",
    ]
    # Unqualified ARN + ":*" for versions (invoke --qualifier N) and the alias (live).
    resources = [
      aws_lambda_function.app.arn,
      "${aws_lambda_function.app.arn}:*",
    ]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "deploy-least-privilege"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy.json
}
