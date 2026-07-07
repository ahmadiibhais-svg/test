# user-sim load generator — NOT a service (SERVICES.md): an on-demand task,
# run via `aws ecs run-task` for the scale-out demo, exactly like the seed
# task is a K8s Job. Image stays Docker Hub direct on purpose: it's a test
# TOOL, not part of the application supply chain (documented trade-off).

#tfsec:ignore:aws-cloudwatch-log-group-customer-key -- accepted 2026-07-07: same rationale as service log groups
resource "aws_cloudwatch_log_group" "loadtest" {
  name              = "/ecs/sockshop/loadtest"
  retention_in_days = 7
}

resource "aws_ecs_task_definition" "loadtest" {
  family                   = "sockshop-loadtest"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  # Reuses the seed task's execution role: identical needs (pull + logs, no secrets).
  execution_role_arn = aws_iam_role.seed_execution.arn

  container_definitions = jsonencode([
    {
      name      = "user-sim"
      image     = "weaveworksdemos/load-test:0.1.1"
      essential = true

      # Flags verified from the task's own logs (2026-07-07): -r is TOTAL
      # REQUESTS (not a rate!), -c concurrent clients. 10 clients ~ 30 req/s,
      # so 10000 requests ~ 5-6 sustained minutes — what target tracking needs
      # (3+ min above target). ALB DNS resolved by Terraform: always aimed at
      # the CURRENT load balancer, every rebuild.
      command = ["-r", "10000", "-c", "10", "-h", module.alb.alb_dns_name]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.loadtest.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "user-sim"
        }
      }
    }
  ])
}
