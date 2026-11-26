output "state_bucket_name" {
  description = "Use as `bucket` in infra/ backend \"s3\" block."
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_region" {
  description = "Use as `region` in infra/ backend \"s3\" block."
  value       = var.region
}
