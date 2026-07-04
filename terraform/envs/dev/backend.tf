# Remote state: this root's state lives in the bootstrap-created S3 bucket.
#
# Values are hard-coded ON PURPOSE: backend config is evaluated at `terraform init`,
# before variables exist — Terraform cannot interpolate anything here. This is a
# well-known TF constraint, not sloppiness.
terraform {
  backend "s3" {
    bucket = "avertra-sockshop-tfstate-448049810701"
    key    = "envs/dev/terraform.tfstate" # path-style key leaves room for envs/prod later
    region = "us-east-1"

    # Native S3 state locking (TF >= 1.10): a lock object placed next to the state
    # file stops two concurrent applies corrupting it — no DynamoDB table needed
    # (older setups you'll see online use one; that pattern is obsolete since 1.10).
    use_lockfile = true
  }
}
