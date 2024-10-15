# =========================================================
# General
# =========================================================

variable "environment" {
    type        = string
    description = "Deployment environment (dev, test, prod, devtest, qa)."

    validation {
        condition     = contains(["dev", "test", "prod", "devtest", "qa"], var.environment)
        error_message = "Must be one of: dev; test; prod; devtest; qa."
    }
}

# =========================================================
# Settings
# =========================================================

variable "destination_registry" {
    type        = object({
                    id     = string
                    region = string
                })
    description = "ECR Registry to replicate to. If not specified, then the current account and region of the destination provider."
    default     = null
}

variable "destination_secret_name" {
    type        = string
    description = "Name of the secret to create to store the destination credentials. If not specified, it will use '{name}-credentials'."
    default     = null
}

variable "source_registry" {
    type        = object({
                    id     = string
                    region = string
                })
    description = "ECR Registry to replicate from. If not specified, then the current account and region."
    default     = null
}

variable "source_prefixes" {
    type        = list(string)
    description = "List of repository prefixes in the source registry to replicate. If not specified, all repositories are replicated."
    default     = []
}

variable "source_wildcards" {
    type        = list(string)
    description = "List of wildcard matches for repository names in the source registry to replicate. If not specified, all repositories are replicated."
    default     = []
}

# =========================================================
# Lambda
# =========================================================

variable "name" {
    type        = string
    description = "Unique name of the function."
    default     = "partitionECRReplicate"
}

variable "description" {
    type        = string
    description = "Description of the function."
    default     = "Replicate ECR Images between registries in different partitions."
}

variable "deploy_localzip" {
    type        = string
    description = "Path to the zip file to deploy."
    default     = null
}

variable "deploy_s3zip" {
    type        = object({
                    bucket = string
                    prefix = optional(string, "")
                    latest = optional(bool, false)
                })
    description = "S3 bucket and prefix to the partitionECRReplicate/environment.zip file to deploy."
    default     = null

    validation {
        condition     = var.deploy_s3zip == null ? true : can(regex("^(.+/)?$", var.deploy_s3zip.prefix))
        error_message = "Prefix must be empty or end with a '/'."
    }
}

variable "environment_variables" {
    type        = map(string)
    description = "Extra environment variables to set for the Lambda."
    default     = {}
}

variable "error_alarm_threshold" {
    type        = number
    description = "Number of Lambda errors in 3 consecutive 5min periods before an alarm is triggered."
    default     = 1
}

variable "function_tags" {
    type        = map(string)
    description = "Extra tags to add to the Lambda function only."
    default     = {}
}

variable "notifications_topic_arn" {
    type        = string
    description = "SNS Topic to notify when a large number of errors is recorded on the Lambda."
    default     = null
}

# =========================================================
# ECS
# =========================================================

variable "ecs_cluster_name" {
    type        = string
    description = "Name of the ECS Cluster to run the task."
    default     = "default"

    validation {
        condition     = length(var.ecs_cluster_name) > 0
        error_message = "Must be a non-empty string."
    }
}

variable "ecs_image" {
    type        = object({
                    prefix      = optional(string, "")
                    registry_id = optional(string)
                    latest      = optional(bool, false)
                })
    description = "ECR image to deploy, using the given registry and prefix. The repository must be '{prefix}partition-ecr-replicate' and the tag the environment."
    default     = null

    validation {
        condition     = var.ecs_image == null ? true : can(regex("^(.+/)?$", var.ecs_image.prefix))
        error_message = "Prefix must be empty or end with a '/'."
    }
}

variable "subnet_ids" {
    type        = list(string)
    description = "Subnet IDs to run the task on."

    validation {
        condition     = length(var.subnet_ids) > 0
        error_message = "Must be a non-empty list."
    }

    validation {
        condition     = alltrue([ for s in var.subnet_ids : can(regex("subnet-[0-9a-f]{8,17}", s)) ])
        error_message = "Must be a list of subnet IDs."
    }
}

variable "vpc_id" {
    type        = string
    description = "VPC ID that contains the subnets."

    validation {
        condition     = can(regex("vpc-[0-9a-f]{8,17}", var.vpc_id))
        error_message = "Must be a VPC ID."
    }
}

variable "worker_cpu" {
    type        = number
    description = "CPU units to allocate to the worker task."
    default     = 512
}

variable "worker_memory" {
    type        = number
    description = "Memory in MiB to allocate to the worker task."
    default     = 1024
}

variable "worker_log_group_name" {
    type        = string
    description = "Name of the CloudWatch Log Group to send the worker logs to."
    default     = null
}

# =========================================================
# Logging
# =========================================================

variable "log_encryption_arn" {
    type        = string
    description = "KMS Key ARN to encrypt to this log group."
    default     = null
}

variable "log_subscription_arn" {
    type        = string
    description = "Lambda function ARN to subscribe to this log group."
    default     = null
}
