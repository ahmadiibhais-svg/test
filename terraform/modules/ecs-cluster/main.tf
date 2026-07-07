resource "aws_service_discovery_http_namespace" "this" {
  name        = var.name
  description = "Service Connect namespace for the sock-shop services"
}

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  service_connect_defaults {
    namespace = aws_service_discovery_http_namespace.this.arn
  }
}
