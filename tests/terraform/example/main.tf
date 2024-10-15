# =========================================================
# Terraform
# =========================================================

terraform {
    required_version = "~> 1.0"
    required_providers {
        aws = {
            source  = "hashicorp/aws"
            version = ">= 4.9"
        }
    }
}

provider "aws" {
    region = "us-east-2"
}

data "aws_ecr_image" "this_worker" {
    repository_name = "test"
    image_tag       = "latest"
}

output "image" {
    value = data.aws_ecr_image.this_worker
}
