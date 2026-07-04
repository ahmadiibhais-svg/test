variable "name" {
  description = "Prefix for resource names and Name tags."
  type        = string
  default     = "sockshop"
}

variable "vpc_id" {
  description = "VPC to create the ALB + its security group in (from the network module)."
  type        = string
}

variable "public_subnet_ids" {
  description = "The two public subnets — an ALB requires at least two AZs."
  type        = list(string)
}

variable "target_port" {
  description = <<-EOT
    Container port of the one service behind the ALB. No default on purpose:
    the root must state it explicitly, pinned to SERVICES.md (front-end = 8079).
  EOT
  type        = number
}

variable "health_check_path" {
  description = "Path the ALB probes to decide target health (front-end serves '/')."
  type        = string
  default     = "/"
}
