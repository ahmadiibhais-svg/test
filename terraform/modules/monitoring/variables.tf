variable "project" {
  description = "Prefix for topic/dashboard/alarm names."
  type        = string
  default     = "sockshop"
}

variable "aws_region" {
  description = "Dashboard widgets carry an explicit region."
  type        = string
}

variable "alert_email" {
  description = "Where alarm emails go. SNS sends a confirmation link — IT MUST BE CLICKED."
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB CloudWatch dimension (from the alb module)."
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name (metric dimension)."
  type        = string
}

variable "service_names" {
  description = "All ECS services — one CPU/memory line each on the dashboard."
  type        = list(string)
}

variable "frontend_service_name" {
  description = "The service that gets its own CPU alarm (the public-facing one)."
  type        = string
  default     = "front-end"
}

variable "rds_identifier" {
  description = "RDS instance identifier (metric dimension)."
  type        = string
}

variable "p99_latency_threshold_seconds" {
  description = <<-EOT
    Alarm threshold for ALB TargetResponseTime p99. A VARIABLE on purpose:
    the Phase-4 acceptance test drops it temporarily (e.g. 0.05) to fire a real
    alarm email, then restores the honest 2s.
  EOT
  type        = number
  default     = 2
}
