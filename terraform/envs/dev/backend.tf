terraform {
  backend "s3" {
    bucket = "avertra-sockshop-tfstate-448049810701"
    key    = "envs/dev/terraform.tfstate"
    region = "us-east-1"

    use_lockfile = true
  }
}
