# =========================================================
# Data
# =========================================================

data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "assume_codebuild" {
    statement {
        effect = "Allow"

        actions = [ "sts:AssumeRole" ]

        principals {
            type        = "Service"
            identifiers = [ "codebuild.amazonaws.com" ]
        }

        condition {
            test     = "ArnLike"
            variable = "aws:SourceArn"
            values   = [ "arn:${local.partition}:codebuild:${local.region_name}:${local.account_id}:project/*" ]
        }

        condition {
            test     = "StringEquals"
            variable = "aws:SourceAccount"
            values   = [ local.account_id ]
        }
    }
}

# =========================================================
# Data: Destincation
# =========================================================

data "aws_partition" "destination" {
    provider = aws.destination
}

data "aws_region" "destination" {
    provider = aws.destination
}

data "aws_caller_identity" "destination" {
    provider = aws.destination
}

# =========================================================
# Locals
# =========================================================

locals {
    partition   = data.aws_partition.current.partition
    region_name = data.aws_region.current.name
    account_id  = data.aws_caller_identity.current.account_id

    dest_partition   = data.aws_partition.destination.partition
    dest_region_name = data.aws_region.destination.name
    dest_account_id  = data.aws_caller_identity.destination.account_id

    is_debug = var.environment != "prod"

    destination_registry = var.destination_registry != null ? var.destination_registry : {
        id     = local.dest_account_id
        region = local.dest_region_name
    }
    source_registry = var.source_registry != null ? var.source_registry : {
        id     = local.account_id
        region = local.region_name
    }
}

# =========================================================
# Artifacts
# =========================================================

locals {
    worker_image = var.worker_image == null ? {
        prefix      = ""
        registry_id = local.account_id
        latest      = false
    } : {
        prefix      = var.worker_image.prefix
        registry_id = coalesce(var.worker_image.registry_id, local.account_id)
        latest      = var.worker_image.latest
    }
    worker_image_url = "${local.worker_image.registry_id}.dkr.ecr.${local.region_name}.amazonaws.com/${local.worker_image.prefix}partition-ecr-replicate:${local.worker_image.latest ? "latest" : var.environment}"
}

data "aws_s3_object" "this" {
    count = var.deploy_s3zip == null ?  0 : 1

    bucket = var.deploy_s3zip.bucket
    key    = "${var.deploy_s3zip.prefix}partitionECRReplicate/${var.deploy_s3zip.latest ? "latest" : var.environment}.zip"
}

# We don't actually use this, it is just to check that the image exists
data "aws_ecr_image" "this" {
    registry_id     = local.worker_image.registry_id
    repository_name = "${local.worker_image.prefix}partition-ecr-replicate"
    image_tag       = local.worker_image.latest ? "latest" : var.environment
}
