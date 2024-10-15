# =========================================================
# Locals
# =========================================================

locals {
    worker_log_group_name = coalesce(var.worker_log_group_name, "/ecs/${var.name}-worker")
}

# =========================================================
# Resources
# =========================================================

resource "aws_cloudwatch_log_group" "this_worker" {
    name = local.worker_log_group_name

    retention_in_days = local.is_debug ? 7 : 30
    kms_key_id        = var.log_encryption_arn
}

resource "aws_cloudwatch_log_subscription_filter" "lambda_logs_subscription" {
    depends_on = [
        module.this_event,
        module.this_queue,
        aws_cloudwatch_log_group.this_worker,
    ]
    for_each = var.log_subscription_arn == null ? {} : {
        event = module.this_event.lambda_cloudwatch_log_group_name
        queue = module.this_queue.lambda_cloudwatch_log_group_name
        worker = local.worker_log_group_name
    }

    name           = uuid()
    log_group_name = each.value

    destination_arn = var.log_subscription_arn
    filter_pattern  = ""
    distribution    = "ByLogStream"

    lifecycle {
        ignore_changes = [ name ]
    }
}
