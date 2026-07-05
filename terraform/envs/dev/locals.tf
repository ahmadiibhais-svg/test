# Our registry — after the Phase-3 flip, every service deploys from HERE, never
# from Docker Hub: images enter only via the pipeline (pull -> scan -> push),
# and ECS pulls layers over the free S3 gateway endpoint instead of the NAT toll.
locals {
  ecr = "448049810701.dkr.ecr.us-east-1.amazonaws.com/sockshop"
}
