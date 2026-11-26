# Account ID makes the bucket name globally unique without hardcoding it in a public repo.
data "aws_caller_identity" "current" {}

locals {
  state_bucket_name = "guarded-deploy-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  # Losing this bucket loses the record of everything infra/ manages.
  # Terraform refuses any plan that would destroy it.
  lifecycle {
    prevent_destroy = true
  }
}

# Every state write keeps the previous version, so a corrupted/bad state can be rolled back.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 (AES256, AWS-managed keys): encrypted at rest at no extra cost.
# A customer-managed KMS key would cost ~$1/month plus per-request charges.
# Reason: CMK costs $1/key-month + $0.03/10k req (credit-funded Free plan); see DECISIONS.md. Re-decide at credit expiry.
#trivy:ignore:AWS-0132:exp:2027-04-23
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Belt and braces: no ACL or bucket policy can ever make state public.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACLs disabled: the bucket owner owns every object; access is controlled by IAM/policy only.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Versioning without expiry grows forever; this caps storage cost of old state versions.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Lifecycle rules on a versioned bucket must be applied after versioning is on.
  depends_on = [aws_s3_bucket_versioning.state]
}

# Reject any request that is not over HTTPS (state must never travel in plaintext).
data "aws_iam_policy_document" "state_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json

  # Putting a policy before the public-access block exists can race; order them.
  depends_on = [aws_s3_bucket_public_access_block.state]
}
