locals {
  seed_dump = file("${path.module}/seed/dump.sql")

  seed_script = <<-EOT
    set -e
    echo "1/3 aligning user auth plugin for the 2017 Go driver..."
    mysql --host="$DB_HOST" --user="$DB_USER" --connect-timeout=20 \
      -e "ALTER USER '$DB_USER'@'%' IDENTIFIED WITH mysql_native_password BY '$MYSQL_PWD';"
    echo "2/3 importing dump.sql..."
    printf '%s' "$DUMP_SQL" | mysql --host="$DB_HOST" --user="$DB_USER" --database="$DB_NAME"
    echo "3/3 verifying..."
    mysql --host="$DB_HOST" --user="$DB_USER" --database="$DB_NAME" -e "SELECT COUNT(*) AS sock_count FROM sock;"
    echo "SEED COMPLETE"
  EOT
}

#tfsec:ignore:aws-cloudwatch-log-group-customer-key -- accepted 2026-07-07: same rationale as service log groups
resource "aws_cloudwatch_log_group" "seed" {
  name              = "/ecs/sockshop/seed"
  retention_in_days = 7
}

resource "aws_iam_role" "seed_execution" {
  name = "sockshop-seed-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "seed_execution" {
  role       = aws_iam_role.seed_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "seed_ssm" {
  name = "read-rds-password"
  role = aws_iam_role.seed_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ssm:GetParameters"
      Resource = [module.rds.password_parameter_arn]
    }]
  })
}

resource "aws_ecs_task_definition" "seed" {
  family                   = "sockshop-seed"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.seed_execution.arn

  container_definitions = jsonencode([
    {
      name      = "seed"
      image     = "mysql:8.0"
      essential = true
      command   = ["sh", "-c", local.seed_script]

      environment = [
        { name = "DB_HOST", value = module.rds.address },
        { name = "DB_USER", value = module.rds.username },
        { name = "DB_NAME", value = module.rds.db_name },
        { name = "DUMP_SQL", value = local.seed_dump },
      ]

      secrets = [
        { name = "MYSQL_PWD", valueFrom = module.rds.password_parameter_arn }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.seed.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "seed"
        }
      }
    }
  ])
}
