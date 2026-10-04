variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project slug used for resource naming."
  type        = string
  default     = "notes"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "staging"

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be one of: staging, production."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

# ---------------------------------------------------------------- networking
variable "single_nat_gateway" {
  description = "true = one NAT gateway for the whole VPC (cheaper, no AZ HA). false = one per AZ."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------- application
variable "container_port" {
  description = "Port the application container listens on."
  type        = number
  default     = 3000
}

variable "container_image" {
  description = "Full container image URI. Leave empty to use the ECR repository this stack creates, tagged :latest."
  type        = string
  default     = ""
}

variable "task_cpu" {
  description = "Fargate task CPU units (1024 = 1 vCPU)."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Initial number of tasks."
  type        = number
  default     = 1
}

variable "min_capacity" {
  description = "Minimum tasks when autoscaling."
  type        = number
  default     = 1
}

variable "max_capacity" {
  description = "Maximum tasks when autoscaling."
  type        = number
  default     = 4
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days."
  type        = number
  default     = 14
}

variable "acm_certificate_arn" {
  description = "Optional ACM certificate ARN. When set, the ALB terminates HTTPS on 443 and 301s HTTP to HTTPS."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------- data
variable "db_name" {
  description = "PostgreSQL database name."
  type        = string
  default     = "notes"
}

variable "db_username" {
  description = "PostgreSQL master username."
  type        = string
  default     = "notes_admin"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_engine_version" {
  description = "PostgreSQL engine version. Must be an engine version actually offered in the target region — list them with: aws rds describe-db-engine-versions --engine postgres --query 'DBEngineVersions[].EngineVersion' --output text"
  type        = string
  default     = "16.15"
}

variable "db_allocated_storage" {
  description = "Allocated storage in GiB."
  type        = number
  default     = 20
}

variable "db_multi_az" {
  description = "Enable Multi-AZ for the RDS instance."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = "RDS automated backup retention in days. 0 disables backups (never do this in production)."
  type        = number
  default     = 7

  validation {
    condition     = var.db_backup_retention_days >= 1
    error_message = "db_backup_retention_days must be >= 1 — backups are a stated requirement."
  }
}

variable "db_deletion_protection" {
  description = "Refuse to destroy the RDS instance. Must be true in production."
  type        = bool
  default     = true
}

# ----------------------------------------------------------------- alerting
variable "alarm_email" {
  description = "Email address subscribed to the alerting SNS topic. Leave empty to skip the subscription."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Monthly AWS budget in USD that triggers a warning alarm at 80%."
  type        = number
  default     = 100
}

variable "tags" {
  description = "Additional tags merged into every resource."
  type        = map(string)
  default     = {}
}
