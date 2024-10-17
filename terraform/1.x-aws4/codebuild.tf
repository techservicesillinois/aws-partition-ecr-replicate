# =========================================================
# Data
# =========================================================

data "aws_iam_policy_document" "this_worker" {
    statement {
        sid    = "Logs"
        effect = "Allow"

        actions = [
            "logs:CreateLogStream",
            "logs:PutLogEvents",
        ]
        resources = [ aws_cloudwatch_log_group.this_worker.arn ]
    }

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
            "ecr:CompleteLayerUpload",
            "ecr:GetDownloadUrlForLayer",
        ]

        resources = length(var.source_prefixes) > 0 ? [
            for p in var.source_prefixes :
            "arn:${local.partition}:ecr:${local.source_registry.region}:${local.source_registry.id}:repository/${p}*"
        ] : [
            "arn:${local.partition}:ecr:${local.source_registry.region}:${local.source_registry.id}:repository/*",
        ]
    }

    statement {
        sid    = "SecretsManager"
        effect = "Allow"

        actions = [
            "secretsmanager:GetSecretValue",
        ]
        resources = [ aws_secretsmanager_secret.dest_credentials.arn ]
    }

    statement {
        sid = "DynamoDB"
        effect = "Allow"

        actions = [
            "dynamodb:BatchGetItem",
            "dynamodb:BatchWriteItem",
            "dynamodb:DeleteItem",
            "dynamodb:GetItem",
            "dynamodb:PutItem",
            "dynamodb:Query",
            "dynamodb:Scan",
            "dynamodb:UpdateItem",
        ]
        resources = [ aws_dynamodb_table.records.arn ]
    }
}

# =========================================================
# Resources: IAM
# =========================================================

resource "aws_iam_role" "this_worker" {
    name_prefix = "${var.name}-worker-"
    path        = "/${var.name}/"
    description = "Role for the CodeBuild Project to replicate ECR Images between registries in different partitions."

    assume_role_policy = data.aws_iam_policy_document.assume_codebuild.json
}

resource "aws_iam_role_policy" "this_worker" {
    name   = "replicate"
    role   = aws_iam_role.this_worker.name
    policy = data.aws_iam_policy_document.this_worker.json
}

# =========================================================
# Resources: CodeBuild
# =========================================================

resource "aws_codebuild_project" "this_worker" {
    depends_on = [
        data.aws_ecr_image.this,

        aws_iam_role.this_worker,
        aws_iam_role_policy.this_worker,
    ]

    name         = "${var.name}-worker"
    description  = "CodeBuild Project to replicate ECR Images between registries in different partitions."
    service_role = aws_iam_role.this_worker.arn

    build_timeout = 15

    source {
        type      = "NO_SOURCE"
        buildspec = file("${path.module}/files/worker-buildspec.yml")
    }

    artifacts {
        type = "NO_ARTIFACTS"
    }

    environment {
        image           = local.worker_image_url
        type            = "LINUX_CONTAINER"
        compute_type    = var.worker_compute_type
        privileged_mode = true

        dynamic "environment_variable" {
            for_each = {
                AWS_REGION         = local.region_name
                AWS_DEFAULT_REGION = local.region_name
                RECORDS_TABLE      = aws_dynamodb_table.records.name

                DEST_REPO_REGION = local.destination_registry.region
                DEST_REGISTRY_ID = local.destination_registry.id
                DEST_SECRET      = aws_secretsmanager_secret.dest_credentials.arn

                SRC_REPO_REGION = local.source_registry.region
                SRC_REGISTRY_ID = local.source_registry.id
            }

            content {
                type  = "PLAINTEXT"
                name  = environment_variable.key
                value = environment_variable.value
            }
        }
    }

    logs_config {
        cloudwatch_logs {
            status      = "ENABLED"
            group_name  = aws_cloudwatch_log_group.this_worker.name
            stream_name = "worker"
        }
    }
}
