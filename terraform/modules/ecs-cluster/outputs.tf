output "cluster_id" {
  description = "Cluster ARN — every ecs-service instance attaches to this."
  value       = aws_ecs_cluster.this.id
}

output "cluster_name" {
  description = "Plain name — used by CLI commands and dashboards."
  value       = aws_ecs_cluster.this.name
}

output "namespace_arn" {
  description = "Service Connect namespace ARN — services register here."
  value       = aws_service_discovery_http_namespace.this.arn
}
