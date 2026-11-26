variable "region" {
  description = "AWS region for the state bucket (same region as infra/)."
  type        = string
  default     = "ap-southeast-1"
}

variable "noncurrent_version_retention_days" {
  description = "Days to keep old (noncurrent) state versions before S3 deletes them."
  type        = number
  default     = 90
}
