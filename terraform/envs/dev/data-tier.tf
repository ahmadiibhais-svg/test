module "rabbitmq" {
  source = "../../modules/ecs-service"

  name          = "rabbitmq"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  image          = "${local.ecr}/rabbitmq:stable"
  container_port = 5672

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.data.id]
}

module "carts_db" {
  source = "../../modules/ecs-service"

  name          = "carts-db"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  image          = "${local.ecr}/carts-db:stable"
  container_port = 27017

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.data.id]
}

module "orders_db" {
  source = "../../modules/ecs-service"

  name          = "orders-db"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  image          = "${local.ecr}/orders-db:stable"
  container_port = 27017

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.data.id]
}

module "user_db" {
  source = "../../modules/ecs-service"

  name          = "user-db"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  image          = "${local.ecr}/user-db:stable"
  container_port = 27017

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.data.id]
}

module "session_db" {
  source = "../../modules/ecs-service"

  name          = "session-db"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  image          = "${local.ecr}/session-db:stable"
  container_port = 6379

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.data.id]
}
