# =========================================================
# Data
# =========================================================

data "aws_iam_policy" "ecs_task_execution" {
    arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "this_worker" {
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

resource "aws_iam_role" "this_worker_exec" {
    name_prefix = "${var.name}-workerexec-"
    path        = "/${var.name}/"
    description = "Role for ECS to launch the worker tasks."

    assume_role_policy = data.aws_iam_policy_document.assume_ecs_tasks.json
}

resource "aws_iam_role_policy_attachment" "this_worker_exec" {
    role       = aws_iam_role.this_worker_exec.name
    policy_arn = data.aws_iam_policy.ecs_task_execution.arn
}

resource "aws_iam_role" "this_worker" {
    name_prefix = "${var.name}-worker-"
    path        = "/${var.name}/"
    description = "Role for the ECS Task to replicate ECR Images between registries in different partitions."

    assume_role_policy = data.aws_iam_policy_document.assume_ecs_tasks.json
}

resource "aws_iam_role_policy" "this_worker" {
    name   = "replicate"
    role   = aws_iam_role.this_worker.name
    policy = data.aws_iam_policy_document.this_worker.json
}

# =========================================================
# Resources: EC2
# =========================================================

resource "aws_security_group" "this_worker" {
    name_prefix = "${var.name}-worker-"
    description = "Security Group for the ECS Worker Task."
    vpc_id      = var.vpc_id

    egress {
        from_port        = 0
        to_port          = 0
        protocol         = "-1"
        cidr_blocks      = ["0.0.0.0/0"]
        ipv6_cidr_blocks = ["::/0"]
    }

    tags = {
        Name = "${var.name}-worker"
    }
}


# =========================================================
# Resources: ECS
# =========================================================

resource "aws_ecs_task_definition" "this_worker" {
    depends_on = [
        data.aws_ecr_image.this,

        aws_iam_role.this_worker_exec,
        aws_iam_role_policy_attachment.this_worker_exec,

        aws_iam_role.this_worker,
        aws_iam_role_policy.this_worker,
    ]

    family = "${var.name}-worker"
    cpu    = var.worker_cpu
    memory = var.worker_memory

    execution_role_arn = aws_iam_role.this_worker_exec.arn
    task_role_arn      = aws_iam_role.this_worker.arn

    requires_compatibilities = [ "FARGATE" ]
    network_mode             = "awsvpc"
    container_definitions    = jsonencode([
        {
            name       = "replicate"
            image      = local.ecs_image_url
            essential  = true
            privileged = true

            environment = [
                { key = "AWS_REGION", value = local.region_name },
                { key = "AWS_DEFAULT_REGION", value = local.region_name },
                { key = "RECORDS_TABLE", value = aws_dynamodb_table.records.name },

                { key = "DEST_REPO_REGION", value = local.destination_registry.region },
                { key = "DEST_REGISTRY_ID", value = local.destination_registry.id },
                { key = "DEST_SECRET", value = aws_secretsmanager_secret.dest_credentials.arn },

                { key = "SRC_REPO_REGION", value = local.source_registry.region },
                { key = "SRC_REGISTRY_ID", value = local.source_registry.id },
            ]

            logConfiguration = {
                logDriver = "awslogs"
                options = {
                    "awslogs-group"         = aws_cloudwatch_log_group.this_worker.name
                    "awslogs-region"        = local.region_name
                    "awslogs-stream-prefix" = "ecs"
                }
            }
        }
    ])

    runtime_platform {
        operating_system_family = "LINUX"
        cpu_architecture        = "X86_64"
    }
}
