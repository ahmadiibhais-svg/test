variable "aws_region" {
  description = "Region for all assessment resources (locked decision in CLAUDE.md)."
  type        = string
  default     = "us-east-1"
}

variable "ecr_namespace" {
  description = "Prefix for ECR repository names, e.g. sockshop/front-end."
  type        = string
  default     = "sockshop"
}

variable "ecr_repositories" {
  description = <<-EOT
    One ECR repository per Fargate service — 13 total per SERVICES.md
    (the 12 from the locked list + session-db, decision D4).
    catalogue-db is RDS (no image); edge-router is dropped (ALB replaces it).
  EOT
  type        = list(string)
  default = [
    "front-end",
    "catalogue",
    "carts",
    "orders",
    "shipping",
    "queue-master",
    "payment",
    "user",
    "carts-db",
    "orders-db",
    "user-db",
    "rabbitmq",
    "session-db",
  ]
}

variable "budget_limit_usd" {
  description = "Monthly cost budget guardrail (CLAUDE.md: $25/month)."
  type        = number
  default     = 25
}

variable "budget_alert_emails" {
  description = <<-EOT
    Recipients for budget alerts. No default on purpose: set it in
    terraform.tfvars (gitignored) so personal addresses stay out of the repo.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.budget_alert_emails) > 0
    error_message = "At least one alert email is required — a silent budget is no guardrail."
  }
}
