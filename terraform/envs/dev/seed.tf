# One-off RDS seeding task — the K8s Job analog: a task definition with no
# service around it, executed on demand via `aws ecs run-task` (kubectl run
# --restart=Never). Runs a MODERN mysql:8 client, which does three things:
#   1. ALTER USER -> mysql_native_password  (the catalogue-driver compat fix;
#      the server-level parameter is immutable on current RDS MySQL 8.0)
#   2. import seed/dump.sql (versioned in-repo; GRANT line stripped — MySQL 8
#      no longer auto-creates users on GRANT and the master already owns socksdb)
#   3. SELECT COUNT(*) FROM sock  -> the verification, visible in the task's logs
#
# Secret hygiene: the password reaches the container ONLY as env MYSQL_PWD via
# SSM injection (D10). The ALTER statement interpolates $MYSQL_PWD INSIDE the
# container at runtime — never in the task definition, console, or logs.

locals {
  seed_dump = file("${path.module}/seed/dump.sql")

  # Bare $VAR (no braces) on purpose: Terraform only interpolates on ${...},
  # so these pass through to the shell untouched.
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

# The execution role fetches the password to inject it (D10: injection is an
# EXECUTION-role job). Scoped to exactly one parameter.
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
      image     = "mysql:8.0" # official image's entrypoint execs any non-mysqld command
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
