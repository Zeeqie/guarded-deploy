# ---------------- Lambda function, its logs, and its execution role ----------------

# Created by Terraform (not by Lambda on first log write) so retention is set from day one.
# Reason: KMS CMK costs $1/key-month + requests (credit-funded Free plan); CloudWatch encrypts logs at rest by default. See DECISIONS.md.
#trivy:ignore:AWS-0017:exp:2027-04-23
resource "aws_cloudwatch_log_group" "app" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${var.name}-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda_exec" {
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }

  statement {
    sid       = "LinksTableReadWrite"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [aws_dynamodb_table.links.arn]
  }
}

resource "aws_iam_role_policy" "lambda_exec" {
  name   = "least-privilege"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_exec.json
}

# Reason: X-Ray not confirmed free on this Free plan; the app is one function + one table, CloudWatch logs suffice. See DECISIONS.md.
#trivy:ignore:AWS-0066:exp:2027-04-23
resource "aws_lambda_function" "app" {
  function_name = local.function_name
  role          = aws_iam_role.lambda_exec.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.app.repository_url}:${var.initial_image_tag}"
  architectures = ["arm64"]
  memory_size   = 512
  timeout       = 10
  publish       = true # creation publishes version 1, which "live" starts on

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.links.name
      # GIT_SHA deliberately NOT set here: it is baked into the image (Dockerfile ENV).
      # A config value could shadow it and keep reporting the creation SHA after deploys.
    }
  }

  lifecycle {
    # The CD pipeline owns code updates (UpdateFunctionCode). Without this, every
    # `terraform apply` would roll the code back to initial_image_tag.
    ignore_changes = [image_uri]
  }

  depends_on = [
    aws_cloudwatch_log_group.app,
    aws_iam_role_policy.lambda_exec,
    aws_ecr_repository_policy.app,
  ]
}

# The public URL points here, never at a raw version. See docs/learning/lambda-alias.md.
resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.app.function_name
  function_version = aws_lambda_function.app.version

  lifecycle {
    # The CD pipeline moves this alias (vN-1 -> vN, or back on rollback).
    # Without this, `terraform apply` would yank traffic back to version 1.
    ignore_changes = [function_version]
  }
}
