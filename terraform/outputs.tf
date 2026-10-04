# ---- network -------------------------------------------------------------
output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB, NAT)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (ECS tasks, RDS)."
  value       = aws_subnet.private[*].id
}

# ---- application ---------------------------------------------------------
output "app_url" {
  description = "Public URL of the application."
  value       = var.acm_certificate_arn == "" ? "http://${aws_lb.app.dns_name}" : "https://${aws_lb.app.dns_name}"
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer."
  value       = aws_lb.app.dns_name
}

output "ecr_repository_url" {
  description = "Push application images here."
  value       = aws_ecr_repository.app.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.app.name
}

# ---- data ----------------------------------------------------------------
output "rds_endpoint" {
  description = "PostgreSQL endpoint (host:port)."
  value       = aws_db_instance.this.endpoint
}

output "rds_identifier" {
  description = "RDS instance identifier, needed for `aws rds restore-db-instance-to-point-in-time`."
  value       = aws_db_instance.this.id
}

# ---- secrets -------------------------------------------------------------
output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the database connection details."
  value       = aws_secretsmanager_secret.db.arn
}

output "db_secret_name" {
  description = "Name of the database secret. Read it with: aws secretsmanager get-secret-value --secret-id <name> --query SecretString --output text"
  value       = aws_secretsmanager_secret.db.name
}

output "kms_key_arn" {
  description = "KMS CMK used for the secret, the database and the application log group."
  value       = aws_kms_key.secrets.arn
}

# ---- observability -------------------------------------------------------
output "alerts_topic_arn" {
  description = "SNS topic that receives every alarm and the budget warning."
  value       = aws_sns_topic.alerts.arn
}

output "app_log_group" {
  description = "CloudWatch Logs group for application and system logs."
  value       = aws_cloudwatch_log_group.app.name
}

output "alb_access_logs_bucket" {
  description = "S3 bucket holding ALB access logs."
  value       = aws_s3_bucket.alb_logs.id
}

output "dashboard_urls" {
  description = "Links to the two CloudWatch dashboards."
  value = {
    infrastructure = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${local.name_prefix}-infrastructure"
    application    = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${local.name_prefix}-application"
  }
}

# ---- security ------------------------------------------------------------
output "security_group_ids" {
  description = "Security groups in the ALB -> app -> db chain."
  value = {
    alb = aws_security_group.alb.id
    app = aws_security_group.app.id
    db  = aws_security_group.db.id
  }
}
