locals {
  java_opts = "-Xms64m -Xmx128m -XX:+UseG1GC -Djava.security.egd=file:/dev/urandom -Dspring.zipkin.enabled=false"
}

module "catalogue" {
  source = "../../modules/ecs-service"

  name          = "catalogue"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  image          = "${local.ecr}/catalogue:stable"
  container_port = 80

  container_entrypoint = ["sh", "-c"]
  container_command    = ["exec /app -port=80 -DSN=\"$DSN\""]

  secrets = {
    DSN = module.rds.dsn_parameter_arn
  }

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.backend.id]
}

module "user" {
  source = "../../modules/ecs-service"

  depends_on = [module.user_db]

  name          = "user"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  image          = "${local.ecr}/user:stable"
  container_port = 80

  environment = {
    MONGO_HOST = "user-db:27017"
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

  image          = "${local.ecr}/payment:stable"
  container_port = 80

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.backend.id]
}

module "carts" {
  source = "../../modules/ecs-service"

  depends_on = [module.carts_db]

  name          = "carts"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  image          = "${local.ecr}/carts:stable"
  container_port = 80

  cpu    = 512
  memory = 1024

  environment = {
    JAVA_OPTS = local.java_opts
  }

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.backend.id]
}

module "orders" {
  source = "../../modules/ecs-service"

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

  image          = "${local.ecr}/orders:stable"
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

  depends_on = [module.rabbitmq]

  name          = "shipping"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  image          = "${local.ecr}/shipping:stable"
  container_port = 80

  cpu    = 512
  memory = 1024

  environment = {
    JAVA_OPTS = local.java_opts
  }

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.backend.id]
}

module "queue_master" {
  source = "../../modules/ecs-service"

  depends_on = [module.rabbitmq]

  name          = "queue-master"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  image          = "${local.ecr}/queue-master:stable"
  container_port = 80

  cpu    = 512
  memory = 1024

  environment = {
    JAVA_OPTS = local.java_opts
  }

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.backend.id]
}
