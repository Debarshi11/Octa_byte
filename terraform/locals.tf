locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "octabyte-devops-assignment"
    },
    var.tags
  )

  is_production = var.environment == "production"
}
