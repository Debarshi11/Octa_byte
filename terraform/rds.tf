resource "aws_db_subnet_group" "this" {
  name       = "${local.name_prefix}-db"
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = "${local.name_prefix}-db-subnets" }
}

resource "aws_db_parameter_group" "this" {
  name   = "${local.name_prefix}-postgres16"
  family = "postgres16"

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  tags = { Name = "${local.name_prefix}-postgres16" }

  lifecycle {
    create_before_destroy = true
  }
}

# IAM role used by RDS Enhanced Monitoring.
resource "aws_iam_role" "rds_monitoring" {
  name = "${local.name_prefix}-rds-enhanced-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "this" {
  identifier = "${local.name_prefix}-postgres"

  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_allocated_storage * 2
  # gp2 rather than gp3: gp3 has a minimum IOPS/throughput floor that many AZs
  # cannot satisfy for db.t4g.micro, and us-east-1 rejects the combination with
  # InsufficientDBInstanceCapacity. gp2 is universally available at this size.
  # Revisit if the instance class grows past db.t4g.medium.
  storage_type          = "gp2"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.secrets.arn

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  # ---- backup strategy -------------------------------------------------
  backup_retention_period   = var.db_backup_retention_days
  backup_window             = "03:00-04:00"
  maintenance_window        = "sun:04:00-sun:05:00"
  copy_tags_to_snapshot     = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name_prefix}-final-snapshot"
  deletion_protection       = var.db_deletion_protection

  # ---- observability ---------------------------------------------------
  performance_insights_enabled = true
  monitoring_interval          = 60
  monitoring_role_arn          = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports = [
    "postgresql",
    "upgrade",
  ]

  auto_minor_version_upgrade = true

  tags = { Name = "${local.name_prefix}-postgres" }

  # Deliberately no `depends_on` on `aws_secretsmanager_secret_version.db`:
  # that resource reads this instance's address, so depending on it back would
  # be a cycle. Ordering is enforced the other way round — `aws_ecs_service.app`
  # depends on the secret version so the task never starts before the secret
  # has a value.
}

# Alternative secret strategy (documented in docs/CHALLENGES.md), left here as a
# reference. Enabling it removes the password from Terraform state entirely
# because RDS generates and rotates the secret itself:
#
#   resource "aws_db_instance" "this" {
#     ...
#     manage_master_user_password = true
#   }
#
#   # ECS task definition then injects directly from the RDS-managed secret:
#   #   PGUSER     <- "${aws_db_instance.this.master_user_secret[0].secret_arn}:username::"
#   #   PGPASSWORD <- "${aws_db_instance.this.master_user_secret[0].secret_arn}:password::"
