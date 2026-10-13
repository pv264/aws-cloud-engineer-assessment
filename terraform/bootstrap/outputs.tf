output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "github_role_arns" {
  description = "Store these as GitHub repository / environment variables (they are not secrets)."
  value = {
    ci        = aws_iam_role.ci.arn
    plan      = aws_iam_role.plan.arn
    terraform = { for env, role in aws_iam_role.terraform : env => role.arn }
    deploy    = { for env, role in aws_iam_role.deploy : env => role.arn }
  }
}
