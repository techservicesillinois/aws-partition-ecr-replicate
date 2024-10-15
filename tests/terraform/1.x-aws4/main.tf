# =========================================================
# Terraform
# =========================================================

terraform {
    required_version = "~> 1.0"
    required_providers {
        aws = {
            source  = "hashicorp/aws"
            version = "~> 5.32"
        }
    }
}

# =========================================================
# Providers
# =========================================================

provider "aws" {
    region = "us-east-2"
}

provider "aws" {
    alias  = "us_gov_east_1"
    region = "us-gov-east-1"
}

# =========================================================
# Modules
# =========================================================

module "partitionECRReplicate" {
    source = "./module"
    providers = {
        aws = aws
        aws.destination = aws.us_gov_east_1
    }

    environment = "test"

    ecs_image = {
        name   = "partition-ecr-replicate"
        url    = "example/partition-ecr-replicate:latest"
        region = "us-east-2"
    }
    subnet_ids = ["subnet-12345678"]
    vpc_id     = "vpc-12345678"
}
