# =========================================================
# Data
# =========================================================

data "aws_iam_policy_document" "this_queue" {
    statement {
        sid    = "ImagesSQS"
        effect = "Allow"

        actions = [
            "sqs:ChangeMessageVisibility",
            "sqs:GetQueueAttributes",
            "sqs:DeleteMessage",
            "sqs:ReceiveMessage",
        ]
        resources = [ aws_sqs_queue.images.arn ]
    }

    statement {
        sid    = "CodeBuildPassRole"
        effect = "Allow"

        actions = [
            "iam:PassRole",
        ]
        resources = [ aws_iam_role.this_worker.arn ]
    }

    statement {
        sid    = "CodeBuild"
        effect = "Allow"

        actions = [
            "codebuild:BatchGetBuilds",
            "codebuild:StartBuild",
        ]
        resources = [ aws_codebuild_project.this_worker.arn ]
    }

    statement {
        sid    = "DynamoDB"
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
# Modules
# =========================================================

module "this_queue" {
    source  = "terraform-aws-modules/lambda/aws"
    version = "7.4.0"

    function_name = "${var.name}-queue"
    description   = var.description
    handler       = "partition_ecr_replicate.queue_handler"
    runtime       = "python3.11"
    memory_size   = 128
    timeout       = 15*60
    function_tags = var.function_tags

    environment_variables = merge(
        var.environment_variables,
        {
            LOGGING_LEVEL = local.partition == "aws" || local.is_debug ? "DEBUG" : "INFO"

            IMAGES_QUEUE   = aws_sqs_queue.images.url
            IMAGES_PROJECT = aws_codebuild_project.this_worker.name

            RECORDS_TABLE = aws_dynamodb_table.records.name
        },
    )

    create_package         = false
    local_existing_package = var.deploy_s3zip == null ? coalesce(var.deploy_localzip, "${path.module}/../../dist/partitionECRReplicate.zip") : null
    s3_existing_package    = var.deploy_s3zip == null ? null : {
        bucket     = data.aws_s3_object.this[0].bucket
        key        = data.aws_s3_object.this[0].key
        version_id = data.aws_s3_object.this[0].version_id
    }

    cloudwatch_logs_retention_in_days = local.is_debug ? 7 : 30
    cloudwatch_logs_kms_key_id        = var.log_encryption_arn
    logging_log_format                = "JSON"

    create_current_version_async_event_config   = false
    create_current_version_allowed_triggers     = false
    create_unqualified_alias_allowed_triggers   = true
    create_unqualified_alias_async_event_config = true

    allowed_triggers = {
        ObjectsQueue = {
            principal  = "sqs.amazonaws.com"
            source_arn = aws_sqs_queue.images.arn
        }
    }
    event_source_mapping = {
        sqs = {
            event_source_arn        = aws_sqs_queue.images.arn
            function_response_types = [ "ReportBatchItemFailures" ]
            batch_size              = 5
        }
    }

    role_name          = "${var.name}-queue-${local.region_name}"
    attach_policy_json = true
    policy_json        = data.aws_iam_policy_document.this_queue.json
}
