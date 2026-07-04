output "alb_dns_name" {
  description = "The public URL of the whole application — the acceptance-test target."
  value       = aws_lb.this.dns_name
}

output "alb_sg_id" {
  description = "ALB's security group — frontend-sg allows ingress FROM this (next chain link)."
  value       = aws_security_group.alb.id
}

output "target_group_arn" {
  description = "front-end tasks register here (consumed by the ecs-service module)."
  value       = aws_lb_target_group.front_end.arn
}
