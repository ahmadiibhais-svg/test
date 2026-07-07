provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "avertra-sockshop"
      Stack     = "bootstrap"
      ManagedBy = "terraform"
    }
  }
}
