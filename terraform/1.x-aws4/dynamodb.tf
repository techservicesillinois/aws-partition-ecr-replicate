# =========================================================
# Resources
# =========================================================

resource "aws_dynamodb_table" "records" {
    name         = "${var.name}-records"
    billing_mode = "PAY_PER_REQUEST"
    hash_key     = "ID"
    range_key    = "Type"

    attribute {
        name = "ID"
        type = "S"
    }

    attribute {
        name = "Type"
        type = "S"
    }

    ttl {
        attribute_name = "Expires"
        enabled        = true
    }
}
