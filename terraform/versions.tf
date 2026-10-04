terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.67"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state with locking. The bucket and lock table are created by ../bootstrap
  # so they survive `terraform destroy` of this stack.
  #
  # Re-point `bucket` and `dynamodb_table` at your own names before the first
  # `terraform init`. Values here are not sensitive (bucket/table names only) —
  # the sensitive material lives in AWS Secrets Manager, never in state config.
  backend "s3" {
    bucket         = "octabyte-tfstate-537124981528"
    key            = "notes/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "octabyte-tf-locks"
    encrypt        = true
    kms_key_id     = "alias/aws/s3"
  }
}
