# =========================================================
# Data
# =========================================================

data "aws_iam_policy_document" "replicate_user" {
    statement {
        sid    = "ECRGlobalArtifacts"
        effect = "Allow"

        actions = [
            "ecr-public:GetAuthorizationToken",
            "ecr:GetAuthorizationToken",
            "sts:GetServiceBearerToken",
        ]
        resources = [ "*" ]
    }

    statement {
        sid    = "ECRArtifacts"
        effect = "Allow"

        actions = [
            "ecr:BatchGetImage",
            "ecr:BatchCheckLayerAvailability",
            "ecr:BatchDeleteImage",
            "ecr:CompleteLayerUpload",
            "ecr:GetDownloadUrlForLayer",
            "ecr:InitiateLayerUpload",
            "ecr:PutImage",
            "ecr:UploadLayerPart",
        ]

        resources = length(var.source_prefixes) > 0 ? [
            for p in var.source_prefixes :
            "arn:${local.dest_partition}:ecr:${local.destination_registry.region}:${local.destination_registry.id}:repository/${p}*"
        ] : [
            "arn:${local.dest_partition}:ecr:${local.destination_registry.region}:${local.destination_registry.id}:repository/*",
        ]
    }
}

# =========================================================
# Resources
# =========================================================

resource "aws_iam_user" "replicate" {
    provider = aws.destination

    name = "${var.name}-${local.account_id}"
    path = "/${var.name}/"
}

resource "aws_iam_user_policy" "replicate" {
    provider = aws.destination

    name   = "replicate"
    user   = aws_iam_user.replicate.name
    policy = data.aws_iam_policy_document.replicate_user.json
}
