#tfsec:ignore:aws-cloudwatch-log-group-customer-key -- accepted 2026-07-07: CMK for 7-day demo logs adds $1/mo + key policy per group for no threat-model gain; SSE default suffices
resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.project}/${var.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "execution" {
  name = "${var.project}-${var.name}-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "secrets_access" {
  count = length(var.secrets) > 0 ? 1 : 0

  name = "read-injected-secrets"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ssm:GetParameters"
      Resource = values(var.secrets)
    }]
  })
}

resource "aws_iam_role" "task" {
  name = "${var.project}-${var.name}-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${var.project}-${var.name}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    merge(
      {
        name      = var.name
        image     = var.image
        essential = true

        portMappings = [{
          name          = var.name
          containerPort = var.container_port
          protocol      = "tcp"
        }]

        environment = [for k, v in var.environment : { name = k, value = v }]
        secrets     = [for k, v in var.secrets : { name = k, valueFrom = v }]

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = aws_cloudwatch_log_group.this.name
            awslogs-region        = var.aws_region
            awslogs-stream-prefix = var.name
          }
        }
      },
      var.container_entrypoint == null ? {} : { entryPoint = var.container_entrypoint },
      var.container_command == null ? {} : { command = var.container_command },
    )
  ])
}

resource "aws_ecs_service" "this" {
  name            = var.name
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  health_check_grace_period_seconds = var.target_group_arn == null ? null : 60

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  service_connect_configuration {
    enabled   = true
    namespace = var.namespace_arn

    service {
      port_name      = var.name
      discovery_name = var.name

      client_alias {
        dns_name = var.name
        port     = var.container_port
      }
    }
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  dynamic "load_balancer" {
    for_each = var.target_group_arn == null ? [] : [var.target_group_arn]

    content {
      target_group_arn = load_balancer.value
      container_name   = var.name
      container_port   = var.container_port
    }
  }
}
