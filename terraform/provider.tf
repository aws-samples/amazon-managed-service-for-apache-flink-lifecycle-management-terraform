terraform {

  backend "s3" {
    use_lockfile = true
    encrypt = true
  }

  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = ">= 6.10.0"
    }
  }
}

provider "aws" {
  region = var.region
}
