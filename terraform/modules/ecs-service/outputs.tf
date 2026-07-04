output "service_name" {
  description = "ECS service name (CLI ops: update-service, stop-task demos)."
  value       = aws_ecs_service.this.name
}

output "task_definition_arn" {
  description = "Current task definition revision."
  value       = aws_ecs_task_definition.this.arn
}

output "log_group_name" {
  description = "Where this service's logs land."
  value       = aws_cloudwatch_log_group.this.name
}
