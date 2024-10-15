# =========================================================
# Data
# =========================================================

data "aws_iam_policy_document" "this_event" {
    statement {
        sid    = "SQS"
        effect = "Allow"

        actions = [
            "sqs:GetQueueAttributes",
            "sqs:SendMessage",
        ]
        resources = [ aws_sqs_queue.images.arn ]
    }
}


# =========================================================
# Modules
# =========================================================

module "this_event" {
    source  = "terraform-aws-modules/lambda/aws"
    version = "7.4.0"

    function_name = var.name
    description   = var.description
    handler       = "partition_ecr_replicate.event_handler"
    runtime       = "python3.11"
    memory_size   = 128
    timeout       = 30
    function_tags = var.function_tags

    environment_variables = merge(
        var.environment_variables,
        {
            LOGGING_LEVEL = local.partition == "aws" || local.is_debug ? "DEBUG" : "INFO"

            IMAGES_QUEUE = aws_sqs_queue.images.url
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
        ECRNotification = {
            principal  = "events.amazonaws.com"
            source_arn = aws_cloudwatch_event_rule.image_events.arn
        }
    }

    role_name          = "${var.name}-${local.region_name}"
    attach_policy_json = true
    policy_json        = data.aws_iam_policy_document.this_event.json
}
