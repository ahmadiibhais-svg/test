module "front_end" {
  source = "../../modules/ecs-service"

  depends_on = [
    module.catalogue,
    module.user,
    module.carts,
    module.orders,
    module.session_db,
  ]

  name          = "front-end"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  image          = "${local.ecr}/front-end:stable"
  container_port = 8079

  cpu           = 256
  memory        = 512
  desired_count = 2

  environment = {
    SESSION_REDIS = "true"
  }

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.frontend.id]

  target_group_arn = module.alb.target_group_arn
}
