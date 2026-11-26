output "api_url" {
  description = "Public URL (HTTP API $default stage -> alias live)."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "function_name" {
  value = aws_lambda_function.app.function_name
}

output "ecr_repo_url" {
  value = aws_ecr_repository.app.repository_url
}

output "deploy_role_arn" {
  description = "Role GitHub Actions assumes via OIDC (store as a repo variable, not a secret: it is not a credential)."
  value       = aws_iam_role.github_deploy.arn
}
