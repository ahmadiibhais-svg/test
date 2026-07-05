# Data tier — 5 services, all ephemeral by design (documented trade-off:
# prod = DocumentDB/Atlas for the mongos, Amazon MQ for rabbit, ElastiCache for
# redis). user-db re-seeds itself on every start; carts/orders data is demo-
# disposable. Service Connect names MUST match SERVICES.md exactly.

module "rabbitmq" {
  source = "../../modules/ecs-service"

  name          = "rabbitmq"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  image          = "${local.ecr}/rabbitmq:stable" # Phase-3 flip (was rabbitmq:3.6.8; plain, not -management — SERVICES.md)
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

  image          = "${local.ecr}/carts-db:stable" # Phase-3 flip (was mongo:3.4, D5)
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

  image          = "${local.ecr}/orders-db:stable" # Phase-3 flip (was mongo:3.4, D5)
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

  image          = "${local.ecr}/user-db:stable" # Phase-3 flip (was weaveworksdemos/user-db:0.4.0; seed users baked in)
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

  image          = "${local.ecr}/session-db:stable" # Phase-3 flip (was redis:alpine, D4 — now pinned by OUR mirror, not a moving upstream tag)
  container_port = 6379

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.data.id]
}
