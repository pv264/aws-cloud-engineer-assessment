output "alb_arn" {
  value = aws_lb.this.arn
}

output "alb_arn_suffix" {
  description = "Used as the LoadBalancer dimension in CloudWatch metrics."
  value       = aws_lb.this.arn_suffix
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_zone_id" {
  value = aws_lb.this.zone_id
}

output "target_group_arn" {
  value = aws_lb_target_group.app.arn
}

output "target_group_arn_suffix" {
  description = "Used as the TargetGroup dimension in CloudWatch metrics."
  value       = aws_lb_target_group.app.arn_suffix
}

output "legacy_lambda_target_group_arn_suffix" {
  value = try(aws_lb_target_group.legacy_lambda[0].arn_suffix, null)
}

output "request_count_resource_label" {
  description = "Resource label for the ALBRequestCountPerTarget auto-scaling metric."
  value       = "${aws_lb.this.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
}

output "https_listener_arn" {
  value = try(aws_lb_listener.https[0].arn, null)
}
