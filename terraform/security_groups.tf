# Strict least-privilege chain:  ALB  ->  app  ->  database
# Nothing else is reachable. No bastion, no SSH, no public database.

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb"
  description = "Application Load Balancer - public HTTP/HTTPS ingress"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP from the internet (redirects to HTTPS in a real deployment)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from the internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Forward to application tasks"
    from_port   = var.container_port
    to_port     = var.container_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = { Name = "${local.name_prefix}-alb-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "app" {
  name        = "${local.name_prefix}-app"
  description = "ECS application tasks - accepts traffic only from the ALB"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Application port from the load balancer only"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Reach the database"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "HTTPS outbound for ECR image pulls, Secrets Manager and AWS APIs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-app-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "db" {
  name        = "${local.name_prefix}-db"
  description = "RDS PostgreSQL - accepts traffic only from the application tier"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "PostgreSQL from application tasks only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    description = "Outbound for backups and AWS management traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-db-sg" }

  lifecycle {
    create_before_destroy = true
  }
}
