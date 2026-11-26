data "aws_caller_identity" "current" {}

locals {
  account_id    = data.aws_caller_identity.current.account_id
  function_name = var.name
  # Built from strings (not aws_lambda_function.app.arn) so the ECR policy and the
  # function don't depend on each other in a cycle.
  function_arn = "arn:aws:lambda:${var.region}:${local.account_id}:function:${local.function_name}"
}

# ---------------- ECR: where the pipeline pushes images ----------------

# Reason: KMS CMK costs $1/key-month + requests (credit-funded Free plan); AES256 at rest is enough here. See DECISIONS.md.
#trivy:ignore:AWS-0033:exp:2027-04-23
resource "aws_ecr_repository" "app" {
  name = var.name

  # A tag (git SHA) can never be re-pointed at different bytes: what was scanned is what runs.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true # basic scanning: free
  }

  encryption_configuration {
    encryption_type = "AES256" # AWS-managed; a KMS CMK costs $1/key-month
  }
}

# Keep storage cost bounded: only the 5 newest images survive (enough to roll back).
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# Lets the Lambda service pull images for THIS function only (same-account: one side
# of the policy pair is enough). Without it Lambda tries to edit the repo policy itself,
# which would need ecr:SetRepositoryPolicy on whoever calls Create/UpdateFunctionCode.
data "aws_iam_policy_document" "ecr_lambda_pull" {
  statement {
    sid     = "LambdaPullThisFunctionOnly"
    actions = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:sourceArn"
      values   = ["${local.function_arn}*"] # function + its versions/aliases
    }
  }
}

resource "aws_ecr_repository_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy     = data.aws_iam_policy_document.ecr_lambda_pull.json
}

# ---------------- DynamoDB: the link store ----------------

# Reason: KMS CMK costs $1/key-month + requests (credit-funded Free plan); AWS-owned key encrypts at rest for free. See DECISIONS.md.
#trivy:ignore:AWS-0025:exp:2027-04-23
resource "aws_dynamodb_table" "links" {
  name         = "${var.name}-links"
  billing_mode = "PAY_PER_REQUEST" # on-demand: $0 when idle, no capacity to size
  hash_key     = "code"

  attribute {
    name = "code"
    type = "S"
  }

  # No server_side_encryption block = AWS-owned key: encrypted at rest, free.
}

# ---------------- API Gateway HTTP API -> alias "live" ----------------

resource "aws_apigatewayv2_api" "http" {
  name          = var.name
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "live" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_alias.live.invoke_arn # qualified: always the alias, never $LATEST
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "$default" # every method + path goes to FastAPI, which does the routing
  target    = "integrations/${aws_apigatewayv2_integration.live.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default" # URL has no /stage prefix
  auto_deploy = true

  # Cost guard for a public URL: excess requests get 429 before they reach Lambda.
  default_route_settings {
    throttling_burst_limit = 10
    throttling_rate_limit  = 5
  }
}

# Only THIS API may invoke, and only via the "live" alias.
resource "aws_lambda_permission" "apigw_live" {
  statement_id  = "AllowHttpApiInvokeLive"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.app.function_name
  qualifier     = aws_lambda_alias.live.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}
