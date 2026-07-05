output "dashboard_name" {
  description = "Open in console: CloudWatch -> Dashboards -> this."
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}

output "sns_topic_arn" {
  description = "The alert channel (Phase 5 auto-scaling can reuse it)."
  value       = aws_sns_topic.alerts.arn
}
