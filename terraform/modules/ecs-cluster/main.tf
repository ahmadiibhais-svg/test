# ECS cluster module — with Fargate this is a LOGICAL boundary, not machines:
# AWS runs the control plane (no fee), and there are no nodes — each task gets
# its own right-sized micro-VM at launch. Closer to "K8s namespace + scheduler
# defaults" than to a cluster.

# Service discovery registry (the CoreDNS role). Every service publishes its
# discovery name here; names MUST equal the hostnames baked into the sock-shop
# images (catalogue, carts, user-db, ...) — locked list in CLAUDE.md + D4.
resource "aws_service_discovery_http_namespace" "this" {
  name        = var.name
  description = "Service Connect namespace for the sock-shop services"
}

resource "aws_ecs_cluster" "this" {
  name = var.name

  # Container Insights = the cAdvisor/metrics-server role: per-service CPU,
  # memory and task-count metrics into CloudWatch. Phase 4 dashboards and
  # Phase 5 auto-scaling read these. 💰 bills as custom metrics (~$1-3/mo at
  # our scale; gone when the stack is destroyed nightly).
  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  # Every service created in this cluster joins the namespace automatically.
  service_connect_defaults {
    namespace = aws_service_discovery_http_namespace.this.arn
  }
}
