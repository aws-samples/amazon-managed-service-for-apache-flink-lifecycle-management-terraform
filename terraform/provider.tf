terraform {

  backend "s3" {
  }

  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = ">= 5.63.0"
    }
  }
}

provider "aws" {
  region = var.region
}
