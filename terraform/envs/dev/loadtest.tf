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
  execution_role_arn       = aws_iam_role.seed_execution.arn

  container_definitions = jsonencode([
    {
      name      = "user-sim"
      image     = "weaveworksdemos/load-test:0.1.1"
      essential = true

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
