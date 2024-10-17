output "destination_credentials" {
    value = {
        arn  = aws_secretsmanager_secret.dest_credentials.arn
        name = aws_secretsmanager_secret.dest_credentials.name
    }
}

output "lambda_event" {
    value = module.this_event
}

output "lambda_queue" {
    value = module.this_queue
}

output "project_worker" {
    value = aws_codebuild_project.this_worker
}

output "worker_role" {
    value = {
        arn       = aws_iam_role.this_worker.arn
        name      = aws_iam_role.this_worker.name
        unique_id = aws_iam_role.this_worker.unique_id
    }
}

output "replicate_user" {
    value = {
        arn       = aws_iam_user.replicate.arn
        name      = aws_iam_user.replicate.name
        unique_id = aws_iam_user.replicate.unique_id
    }
}
