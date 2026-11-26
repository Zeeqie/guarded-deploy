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

variable "github_repo" {
  description = "owner/repo allowed to assume the deploy role via OIDC."
  type        = string
  default     = "Zeeqie/guarded-deploy"
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
