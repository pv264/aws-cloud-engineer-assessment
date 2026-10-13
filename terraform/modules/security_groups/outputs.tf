output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "app_security_group_id" {
  value = aws_security_group.app.id
}

output "lambda_security_group_id" {
  value = aws_security_group.lambda.id
}

output "db_proxy_security_group_id" {
  value = aws_security_group.db_proxy.id
}

output "db_security_group_id" {
  value = aws_security_group.db.id
}
