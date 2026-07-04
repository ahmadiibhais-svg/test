# ecs-service module — the reusable heart, instantiated once per service (13x).
# Mapping for K8s eyes: task definition = pod spec, service = Deployment,
# Service Connect block = Service registration in DNS.

# ------------------------------------------------------------------ logging
resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.project}/${var.name}"
  retention_in_days = var.log_retention_days
}

# ------------------------------------------------------- the two identities
# EXECUTION role: used by the ECS PLATFORM before/around the container —
# pull image, write logs, (Phase 2) fetch secrets to inject.
# K8s analog: the kubelet's credentials. Pull/log failures point HERE.
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

# Phase-2 extension: services that inject secrets need their EXECUTION role
# (injection is a platform job — L14/D10) allowed to read EXACTLY those
# parameters, nothing wider. count 0/1 = the conditional-resource pattern:
# services without secrets don't even get the policy object.
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

# TASK role: assumed by the APPLICATION CODE for AWS API calls at runtime.
# K8s analog: the pod's ServiceAccount. Deliberately EMPTY — our apps make no
# AWS calls, so their runtime identity has no permissions (least privilege).
# Runtime AccessDenied in app logs would point HERE.
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

# ------------------------------------------------------------ the pod spec
resource "aws_ecs_task_definition" "this" {
  family                   = "${var.project}-${var.name}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc" # each task gets its own ENI + private IP (pod-IPs)
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  # container_definitions is historically a JSON-string field: jsonencode turns
  # clean HCL into that JSON. The for-expressions reshape our friendly maps into
  # the list-of-objects the ECS API demands. merge() + the null-to-{} ternary
  # includes entryPoint/command in the JSON ONLY when a caller sets them
  # (catalogue's sh-wrapper); everyone else keeps the image defaults untouched.
  container_definitions = jsonencode([
    merge(
      {
        name      = var.name
        image     = var.image
        essential = true

        portMappings = [{
          name          = var.name # port name — Service Connect points at this
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

# ---------------------------------------------------------- the Deployment
resource "aws_ecs_service" "this" {
  name            = var.name
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # ALB-attached services get 60s of grace before health checks can kill slow
  # starters (front-end is a slow Node boot); everyone else needs none.
  health_check_grace_period_seconds = var.target_group_arn == null ? null : 60

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false # locked: tasks are unroutable from outside; pulls go via NAT
  }

  # Registers var.name in the sockshop namespace — front-end reaching
  # http://catalogue/ resolves through this. Enabling it also makes this task a
  # Service Connect CLIENT (needed to resolve others).
  service_connect_configuration {
    enabled   = true
    namespace = var.namespace_arn

    service {
      port_name      = var.name # must match the portMapping name above
      discovery_name = var.name

      client_alias {
        # dns_name MUST be explicit: AWS defaults an omitted dnsName to
        # "discoveryName.namespace" (catalogue.sockshop) — but the images dial
        # BARE hostnames (catalogue). Cost of the default: ENOTFOUND everywhere.
        # (Debugging story of 2026-07-04, D12.)
        dns_name = var.name
        port     = var.container_port # the port callers dial
      }
    }
  }

  # The rollback story: if new tasks keep failing to start or go unhealthy
  # during a deploy, ECS halts the rollout and reverts to the last working
  # revision automatically. (Production upgrade path: CodeDeploy blue/green.)
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # dynamic = render this nested block 0..N times; here 0 or 1: only front-end
  # passes a target group; the other 12 instantiations render no block at all.
  dynamic "load_balancer" {
    for_each = var.target_group_arn == null ? [] : [var.target_group_arn]

    content {
      target_group_arn = load_balancer.value
      container_name   = var.name
      container_port   = var.container_port
    }
  }
}
