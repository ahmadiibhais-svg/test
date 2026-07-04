# Instantiate the network module (Helm analogy: `helm install network ./modules/network`).
# Only aws_region is passed; every other input uses the module's defaults —
# they're visible in terraform/modules/network/variables.tf.
module "network" {
  source = "../../modules/network"

  aws_region = var.aws_region
}
