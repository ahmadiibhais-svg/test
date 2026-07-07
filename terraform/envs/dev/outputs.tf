output "private_subnet_ids" {
  description = "Where tasks run — the run-task ceremony's first ingredient."
  value       = module.network.private_subnet_ids
}

output "backend_sg_id" {
  description = "The SG one-off tasks (seed, user-sim) wear."
  value       = aws_security_group.backend.id
}
