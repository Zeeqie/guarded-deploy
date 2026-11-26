variable "region" {
  description = "AWS region for everything in infra/."
  type        = string
  default     = "ap-southeast-1"
}

variable "name" {
  description = "Base name for all resources."
  type        = string
  default     = "guarded-deploy"
}

variable "github_oidc_subject_repo" {
  description = <<-EOT
    Repo part of the GitHub OIDC `sub` claim allowed to assume the deploy role.
    This repo uses GitHub's immutable subject (owner@owner_id/repo@repo_id), so a deleted
    and re-created repo with the same name can't match. Check before changing:
    gh api repos/<owner>/<repo>/actions/oidc/customization/sub (sub_claim_prefix).
  EOT
  type        = string
  default     = "Zeeqie@260482962/guarded-deploy@1431477050"
}

variable "initial_image_tag" {
  description = "ECR tag (git SHA) of the image the function is CREATED with. After creation the pipeline owns the image (ignore_changes), so changing this later has no effect."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{7,40}$", var.initial_image_tag))
    error_message = "initial_image_tag must be a git SHA (7-40 lowercase hex chars)."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the function's log group."
  type        = number
  default     = 7
}
