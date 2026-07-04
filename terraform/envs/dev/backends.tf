# Backend tier — 7 services. Java services (carts/orders/shipping/queue-master)
# get 0.5 vCPU / 1024 MB + JAVA_OPTS (from compose; without it: slow boot + Zipkin
# noise). Go services (catalogue/payment/user) run on the 0.25/512 default.
# All wear backend-sg; Service Connect names match SERVICES.md exactly.

locals {
  java_opts = "-Xms64m -Xmx128m -XX:+UseG1GC -Djava.security.egd=file:/dev/urandom -Dspring.zipkin.enabled=false"
}

# catalogue — the one service with a secret AND a launch wrapper (review catch #2):
# its binary reads the DSN only as a -DSN flag and ECS does no $(VAR) substitution
# in command, so: SSM injects env DSN (D10) -> sh -c turns it into the flag at
# launch. Plaintext DSN never appears in the task definition or console.
module "catalogue" {
  source = "../../modules/ecs-service"

  name          = "catalogue"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  image          = "weaveworksdemos/catalogue:0.3.5"
  container_port = 80

  container_entrypoint = ["sh", "-c"]
  container_command    = ["exec /app -port=80 -DSN=\"$DSN\""] # $DSN expands IN the container

  secrets = {
    DSN = module.rds.dsn_parameter_arn
  }

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.backend.id]
}

module "user" {
  source = "../../modules/ecs-service"

  depends_on = [module.user_db] # D12 ordering

  name          = "user"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  image          = "weaveworksdemos/user:0.4.4" # D6: the pinned compose set
  container_port = 80

  environment = {
    MONGO_HOST = "user-db:27017" # D6: explicit env name from compose
  }

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.backend.id]
}

module "payment" {
  source = "../../modules/ecs-service"

  name          = "payment"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  image          = "weaveworksdemos/payment:0.4.3"
  container_port = 80

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.backend.id]
}

module "carts" {
  source = "../../modules/ecs-service"

  depends_on = [module.carts_db] # D12 ordering

  name          = "carts"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  image          = "weaveworksdemos/carts:0.4.8"
  container_port = 80

  cpu    = 512 # Java floor (CLAUDE.md sizing)
  memory = 1024

  environment = {
    JAVA_OPTS = local.java_opts
  }

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.backend.id]
}

module "orders" {
  source = "../../modules/ecs-service"

  # D12 ordering: orders calls carts/user/payment/shipping — create them first.
  depends_on = [
    module.carts,
    module.user,
    module.payment,
    module.shipping,
  ]

  name          = "orders"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  image          = "weaveworksdemos/orders:0.4.7"
  container_port = 80

  cpu    = 512
  memory = 1024

  environment = {
    JAVA_OPTS = local.java_opts
  }

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.backend.id]
}

module "shipping" {
  source = "../../modules/ecs-service"

  depends_on = [module.rabbitmq] # D12 ordering

  name          = "shipping"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  image          = "weaveworksdemos/shipping:0.4.8"
  container_port = 80

  cpu    = 512
  memory = 1024

  environment = {
    JAVA_OPTS = local.java_opts
  }

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.backend.id]
}

# queue-master: compose mounts docker.sock — NOT replicated on Fargate (impossible
# and unneeded for the demo; documented trade-off in SERVICES.md).
module "queue_master" {
  source = "../../modules/ecs-service"

  depends_on = [module.rabbitmq] # D12 ordering

  name          = "queue-master"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  image          = "weaveworksdemos/queue-master:0.3.1"
  container_port = 80

  cpu    = 512
  memory = 1024

  environment = {
    JAVA_OPTS = local.java_opts
  }

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.backend.id]
}
