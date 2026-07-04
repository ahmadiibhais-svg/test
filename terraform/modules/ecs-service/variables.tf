variable "project" {
  description = "Project prefix for IAM role names and the log-group path."
  type        = string
  default     = "sockshop"
}

variable "name" {
  description = <<-EOT
    Service name — used as: ECS service name, container name, Service Connect
    discovery name, and log-group suffix. MUST equal the hostname baked into the
    images (SERVICES.md locked list): catalogue, carts, user-db, ...
  EOT
  type        = string
}

variable "cluster_id" {
  description = "ECS cluster ARN (from the ecs-cluster module)."
  type        = string
}

variable "namespace_arn" {
  description = "Service Connect namespace ARN (from the ecs-cluster module)."
  type        = string
}

variable "aws_region" {
  description = "Region — the awslogs driver needs it spelled out."
  type        = string
}

variable "image" {
  description = "Full image reference (skeleton: public Docker Hub; later: our ECR + :stable)."
  type        = string
}

variable "container_port" {
  description = "Port the container listens on (SERVICES.md; 80 for most, 8079 front-end...)."
  type        = number
  default     = 80
}

variable "cpu" {
  description = "Fargate CPU units (256 = 0.25 vCPU; Java services get 512)."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Fargate memory in MiB (512 default; Java services get 1024)."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Replicas (K8s: spec.replicas)."
  type        = number
  default     = 1
}

variable "environment" {
  description = "Plain env vars, name -> value (secrets go in var.secrets, never here)."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Secret env vars, name -> SSM parameter ARN (injected by the platform)."
  type        = map(string)
  default     = {}
}

variable "subnet_ids" {
  description = "Private subnets only (locked: no public IPs on tasks)."
  type        = list(string)
}

variable "security_group_ids" {
  description = "The tier's SG(s) — frontend-sg / backend-sg / data-sg."
  type        = list(string)
}

variable "target_group_arn" {
  description = "ALB target group to register with. null = not behind the ALB (12 of 13 services)."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "CloudWatch retention — 7 days keeps demo costs near zero."
  type        = number
  default     = 7
}
