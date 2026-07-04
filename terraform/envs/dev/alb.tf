# The public entry point. First cross-module wiring: network's outputs feed
# the ALB's inputs — the root is the composition layer.
module "alb" {
  source = "../../modules/alb"

  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids

  # front-end's container port — pinned by SERVICES.md (verified from the K8s
  # manifest: containerPort 8079, probes on 8079).
  target_port = 8079
}

# Surface the URL at the root level so `terraform output alb_dns_name` just works.
output "alb_dns_name" {
  description = "Public URL of the storefront."
  value       = module.alb.alb_dns_name
}
