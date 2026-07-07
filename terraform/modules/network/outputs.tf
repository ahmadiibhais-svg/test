output "vpc_id" {
  description = "VPC id — security groups and the ALB need it."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "The VPC's address space."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Where the ALB goes."
  value       = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

output "private_subnet_ids" {
  description = "Where every Fargate task and RDS go."
  value       = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}
