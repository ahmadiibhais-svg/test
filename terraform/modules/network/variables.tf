variable "name" {
  description = "Prefix for Name tags (console readability)."
  type        = string
  default     = "sockshop"
}

variable "aws_region" {
  description = "Region — needed to build the S3 endpoint's service name string."
  type        = string
}

variable "vpc_cidr" {
  description = "Address space of the whole VPC (locked: 10.0.0.0/16 = 65k addresses)."
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Two availability zones = two failure domains (K8s: topology zones)."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "One public subnet per AZ (ALB + NAT live here)."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "One private subnet per AZ (all Fargate tasks + RDS live here)."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}
