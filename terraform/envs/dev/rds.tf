module "rds" {
  source = "../../modules/rds"

  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [aws_security_group.rds.id]

  multi_az = true
}

output "rds_endpoint" {
  description = "RDS host:port (seed step + sanity checks)."
  value       = module.rds.endpoint
}
