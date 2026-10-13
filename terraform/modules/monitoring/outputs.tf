output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "deployment_alarm_names" {
  description = "Alarms that roll back an in-progress ECS deployment."
  value = [
    aws_cloudwatch_metric_alarm.alb_5xx_rate.alarm_name,
    aws_cloudwatch_metric_alarm.alb_p99_latency.alarm_name,
  ]
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.this.dashboard_name
}
