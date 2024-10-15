# =========================================================
# Resources
# =========================================================

resource "aws_sqs_queue" "images" {
    name       = "${var.name}-images.fifo"
    fifo_queue = true

    content_based_deduplication = true
    visibility_timeout_seconds  = 15*60
    message_retention_seconds   = 60*60
}
