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

output "alb_arn_suffix" {
  description = "The ALB's CloudWatch identity — metrics are dimensioned on this, not the ARN."
  value       = aws_lb.this.arn_suffix
}

output "tg_arn_suffix" {
  description = "Target group's metric identity — the request-per-target scaling policy needs alb_suffix/tg_suffix."
  value       = aws_lb_target_group.front_end.arn_suffix
}
