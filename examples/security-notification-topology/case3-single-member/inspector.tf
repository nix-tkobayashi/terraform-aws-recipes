# Inspector only where scannable resources (EC2 / ECR / Lambda) exist.
module "inspector_home" {
  source = "../modules/inspector-region"
}
