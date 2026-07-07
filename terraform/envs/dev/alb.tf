module "alb" {
  source = "../../modules/alb"

  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids

  target_port = 8079
}

output "alb_dns_name" {
  description = "Public URL of the storefront."
  value       = module.alb.alb_dns_name
}
