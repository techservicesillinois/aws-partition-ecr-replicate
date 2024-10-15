
# =========================================================
# Resources
# =========================================================

resource "aws_cloudwatch_event_rule" "image_events" {
    name        = "${var.name}-image-events"
    description = "Queue replication of ECR images."

    event_pattern = jsonencode({
        detail-type = [ "ECR Image Action" ]
        detail = merge(
            {
                result        = [ "SUCCESS" ]
                "action-type" = [ "PUSH", "DELETE" ]
            },
            length(var.source_prefixes) == 0 ? {} : {
                "repository-name" = [ for p in var.source_prefixes : { prefix = p } ]
            },
            length(var.source_wildcards) == 0 ? {} : {
                "repository-name" = [ for w in var.source_wildcards : { wildcard = w } ]
            }
        )
    })

    lifecycle {
        precondition {
            condition     = length(var.source_prefixes) == 0 || length(var.source_wildcards) == 0
            error_message = "Only one of source_prefixes or source_wildcards can be specified."
        }
    }
}

resource "aws_cloudwatch_event_target" "image_events" {
    rule      = aws_cloudwatch_event_rule.image_events.name
    arn       = module.this_event.lambda_function_arn
}
