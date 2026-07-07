module "monitoring" {
  source = "../../modules/monitoring"

  aws_region     = var.aws_region
  alert_email    = "ahmad.ibhaiss@outlook.com"
  alb_arn_suffix = module.alb.alb_arn_suffix
  cluster_name   = module.ecs_cluster.cluster_name
  rds_identifier = module.rds.identifier

  service_names = [
    "front-end", "catalogue", "carts", "orders", "shipping", "queue-master",
    "payment", "user", "carts-db", "orders-db", "user-db", "rabbitmq", "session-db",
  ]

  # p99_latency_threshold_seconds = 0.05  # <- uncomment ONLY for the alarm test-fire
}
