# front-end — the walking skeleton's one service. First instantiation of the
# reusable ecs-service module (12 more follow in Phase 2).
module "front_end" {
  source = "../../modules/ecs-service"

  name          = "front-end"
  cluster_id    = module.ecs_cluster.cluster_id
  namespace_arn = module.ecs_cluster.namespace_arn
  aws_region    = var.aws_region

  # Public image straight from Docker Hub for the skeleton; the Phase-3 pipeline
  # replaces this with our ECR mirror + :stable (D8).
  image          = "weaveworksdemos/front-end:0.3.12"
  container_port = 8079 # SERVICES.md

  cpu           = 256
  memory        = 512
  desired_count = 2 # two tasks across two AZs — the HA baseline

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.frontend.id]

  # The one ALB attachment in the whole system.
  target_group_arn = module.alb.target_group_arn
}
