provider "aws" {
  region = var.aws_region

  # Stamped onto every resource this root creates — the K8s-labels-on-every-object
  # habit. Makes project resources findable in the console and in Cost Explorer.
  default_tags {
    tags = {
      Project   = "avertra-sockshop"
      Stack     = "bootstrap"
      ManagedBy = "terraform"
    }
  }
}
