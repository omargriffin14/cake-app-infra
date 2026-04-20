variable "aws_region" {
  default = "us-east-1"
}

variable "vpc_id" {
  default = "vpc-05181aef674299739"
}

variable "public_subnet_id" {
  default = "subnet-07acabb38c230fed5"
}

variable "private_subnet_id" {
  description = "Private subnet ID for EC2 backend"
}

variable "alb_arn" {
  description = "ARN of the existing ALB"
}

variable "alb_listener_arn" {
  description = "ARN of the existing HTTPS listener on the ALB"
}

variable "rds_endpoint" {
  default = "flask-db.c0pocwom8584.us-east-1.rds.amazonaws.com"
}

variable "db_name" {
  default = "cake_orders"
}

variable "db_username" {
  description = "RDS master username"
}

variable "db_password" {
  description = "RDS master password"
  sensitive   = true
}

variable "ec2_ami" {
  description = "AMI ID for the backend EC2 instance (Amazon Linux 2)"
}

variable "ec2_instance_type" {
  default = "t3.micro"
}

variable "ec2_key_name" {
  description = "Key pair name for EC2 SSH access"
}

variable "app_name" {
  default = "cake-app"
}

variable "alb_security_group_id" {
  description = "Security group ID attached to the existing ALB"
}

variable "ses_email" {
  description = "Email address to verify in SES for sending order confirmations"
}

variable "rds_security_group_id" {
  description = "Security group ID attached to the RDS instance"
}
