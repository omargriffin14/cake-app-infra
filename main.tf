terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ──────────────────────────────────────────
# Security Group — Backend EC2
# ──────────────────────────────────────────
resource "aws_security_group" "backend_sg" {
  name        = "${var.app_name}-backend-sg"
  description = "Allow traffic from ALB to backend"
  vpc_id      = var.vpc_id

  ingress {
    description     = "App port from ALB"
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ──────────────────────────────────────────
# EC2 — Backend (private subnet)
# ──────────────────────────────────────────
resource "aws_instance" "backend" {
  ami                    = var.ec2_ami
  instance_type          = var.ec2_instance_type
  subnet_id              = var.private_subnet_id
  vpc_security_group_ids = [aws_security_group.backend_sg.id]
  key_name               = var.ec2_key_name
  iam_instance_profile   = aws_iam_instance_profile.backend_profile.name

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y docker
    systemctl start docker
    systemctl enable docker
    usermod -aG docker ec2-user
  EOF

  tags = {
    Name = "${var.app_name}-backend"
  }
}

# ──────────────────────────────────────────
# IAM — EC2 role for Secrets Manager access
# ──────────────────────────────────────────
resource "aws_iam_role" "backend_role" {
  name = "${var.app_name}-backend-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "secrets_access" {
  role       = aws_iam_role.backend_role.name
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}

resource "aws_iam_instance_profile" "backend_profile" {
  name = "${var.app_name}-backend-profile"
  role = aws_iam_role.backend_role.name
}

# ──────────────────────────────────────────
# ALB — Target Group + Listener Rule
# ──────────────────────────────────────────
data "aws_lb" "existing_alb" {
  arn = var.alb_arn
}

resource "aws_lb_target_group" "backend_tg" {
  name        = "${var.app_name}-backend-tg"
  port        = 5000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = "/api/health"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group_attachment" "backend_attachment" {
  target_group_arn = aws_lb_target_group.backend_tg.arn
  target_id        = aws_instance.backend.id
  port             = 5000
}

resource "aws_lb_listener_rule" "api_rule" {
  listener_arn = var.alb_listener_arn
  priority     = 10

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend_tg.arn
  }
}

# ──────────────────────────────────────────
# S3 — React Frontend
# ──────────────────────────────────────────
resource "aws_s3_bucket" "frontend" {
  bucket = "${var.app_name}-frontend-${random_id.suffix.hex}"
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ──────────────────────────────────────────
# CloudFront — OAC
# ──────────────────────────────────────────
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${var.app_name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ──────────────────────────────────────────
# CloudFront — Distribution
# ──────────────────────────────────────────
resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  default_root_object = "index.html"

  aliases = ["nelasbakery.com", "www.nelasbakery.com"]

  # ── S3 Frontend Origin ──
  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  # ── ALB Backend Origin ──
  origin {
    domain_name = "flask-alb-1442848183.us-east-1.elb.amazonaws.com"
    origin_id   = "alb-backend"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # ── API Cache Behavior ──
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "alb-backend"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
  }

  # ── Default Cache Behavior (S3 Frontend) ──
  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }

  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.nelasbakery.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# ──────────────────────────────────────────
# S3 Bucket Policy — Frontend OAC
# ──────────────────────────────────────────
resource "aws_s3_bucket_policy" "frontend_oac" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn
        }
      }
    }]
  })
}

# ──────────────────────────────────────────
# Secrets Manager — DB credentials
# ──────────────────────────────────────────
resource "aws_secretsmanager_secret" "db_credentials" {
  name = "${var.app_name}/db-credentials"
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    host     = var.rds_endpoint
    database = var.db_name
    username = var.db_username
    password = var.db_password
    s3_uploads_bucket = aws_s3_bucket.uploads.bucket
  })
}

# ──────────────────────────────────────────
# IAM — SSM Session Manager access
# ──────────────────────────────────────────
resource "aws_iam_role_policy_attachment" "ssm_access" {
  role       = aws_iam_role.backend_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ──────────────────────────────────────────
# Elastic IP — NAT Gateway
# ──────────────────────────────────────────
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.app_name}-nat-eip"
  }
}

# ──────────────────────────────────────────
# NAT Gateway — Public Subnet
# ──────────────────────────────────────────
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = var.public_subnet_id

  tags = {
    Name = "${var.app_name}-nat-gateway"
  }

  depends_on = [aws_eip.nat]
}

# ──────────────────────────────────────────
# Route Table — Private Subnet
# ──────────────────────────────────────────
resource "aws_route_table" "private" {
  vpc_id = var.vpc_id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.app_name}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = var.private_subnet_id
  route_table_id = aws_route_table.private.id
}

# ──────────────────────────────────────────
# S3 — Uploads Bucket (customer images)
# ──────────────────────────────────────────
resource "aws_s3_bucket" "uploads" {
  bucket = "${var.app_name}-uploads-${random_id.suffix.hex}"

  tags = {
    Name = "${var.app_name}-uploads"
  }
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_cors_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST"]
    allowed_origins = ["*"]
    max_age_seconds = 3000
  }
}

# ──────────────────────────────────────────
# IAM — S3 uploads + SES permissions
# ──────────────────────────────────────────
resource "aws_iam_role_policy" "backend_s3_ses" {
  name = "${var.app_name}-backend-s3-ses-policy"
  role = aws_iam_role.backend_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.uploads.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ]
        Resource = "*"
      }
    ]
  })
}

# ──────────────────────────────────────────
# SES — Email Verification
# ──────────────────────────────────────────
resource "aws_ses_email_identity" "bakery" {
  email = var.ses_email
}

# ──────────────────────────────────────────
# RDS Security Group Rule — Cake App Backend
# ──────────────────────────────────────────
resource "aws_security_group_rule" "rds_from_cake_backend" {
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = var.rds_security_group_id
  source_security_group_id = aws_security_group.backend_sg.id
  description              = "Allow MySQL access from cake app backend"
}

# ──────────────────────────────────────────
# Route 53 — Hosted Zone
# ──────────────────────────────────────────
resource "aws_route53_zone" "nelasbakery" {
  name = "nelasbakery.com"
}

# ──────────────────────────────────────────
# ACM — Certificate
# ──────────────────────────────────────────
resource "aws_acm_certificate" "nelasbakery" {
  domain_name               = "nelasbakery.com"
  subject_alternative_names = ["www.nelasbakery.com"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# ──────────────────────────────────────────
# Route 53 — ACM Validation Records
# ──────────────────────────────────────────
resource "aws_route53_record" "acm_validation_apex" {
  zone_id = aws_route53_zone.nelasbakery.zone_id
  name    = "_e1f630d5116452f188a6c84677f5477f.nelasbakery.com"
  type    = "CNAME"
  ttl     = 300
  records = ["_4175c632339a621fa5ae2c946378647c.jkddzztszm.acm-validations.aws"]
}

resource "aws_route53_record" "acm_validation_www" {
  zone_id = aws_route53_zone.nelasbakery.zone_id
  name    = "_1f86df63b76701dc763fb6279e0bae98.www.nelasbakery.com"
  type    = "CNAME"
  ttl     = 300
  records = ["_3855229175d6cca738e73fa5740de3de.jkddzztszm.acm-validations.aws"]
}

# ──────────────────────────────────────────
# Route 53 — A Records pointing to CloudFront
# ──────────────────────────────────────────
resource "aws_route53_record" "apex" {
  zone_id = aws_route53_zone.nelasbakery.zone_id
  name    = "nelasbakery.com"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.frontend.domain_name
    zone_id                = aws_cloudfront_distribution.frontend.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.nelasbakery.zone_id
  name    = "www.nelasbakery.com"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.frontend.domain_name
    zone_id                = aws_cloudfront_distribution.frontend.hosted_zone_id
    evaluate_target_health = false
  }
}

# ──────────────────────────────────────────
# Route 53 — MX Record for SES
# ──────────────────────────────────────────
resource "aws_route53_record" "mx" {
  zone_id = aws_route53_zone.nelasbakery.zone_id
  name    = "nelasbakery.com"
  type    = "MX"
  ttl     = 300
  records = ["10 inbound-smtp.us-east-1.amazonaws.com"]
}

# ──────────────────────────────────────────
# Route 53 — SES Domain Verification TXT
# ──────────────────────────────────────────
resource "aws_route53_record" "ses_verification" {
  zone_id = aws_route53_zone.nelasbakery.zone_id
  name    = "_amazonses.nelasbakery.com"
  type    = "TXT"
  ttl     = 300
  records = ["t69S2mD8h4RDi5TN1CnPsJsRgk+uaHXbLXlUVM2CWQc="]
}

# ──────────────────────────────────────────
# Route 53 — SES DKIM Records
# ──────────────────────────────────────────
resource "aws_route53_record" "dkim_1" {
  zone_id = aws_route53_zone.nelasbakery.zone_id
  name    = "iqpvvvtgg6rxxycqtzhmk6gs2fnbdl3y._domainkey.nelasbakery.com"
  type    = "CNAME"
  ttl     = 300
  records = ["iqpvvvtgg6rxxycqtzhmk6gs2fnbdl3y.dkim.amazonses.com"]
}

resource "aws_route53_record" "dkim_2" {
  zone_id = aws_route53_zone.nelasbakery.zone_id
  name    = "aiovy7hilc443sjgi3umt2l2l3zzhc5m._domainkey.nelasbakery.com"
  type    = "CNAME"
  ttl     = 300
  records = ["aiovy7hilc443sjgi3umt2l2l3zzhc5m.dkim.amazonses.com"]
}

resource "aws_route53_record" "dkim_3" {
  zone_id = aws_route53_zone.nelasbakery.zone_id
  name    = "ovhj77f76y2t6j6jhfowfu77ltw4ivtb._domainkey.nelasbakery.com"
  type    = "CNAME"
  ttl     = 300
  records = ["ovhj77f76y2t6j6jhfowfu77ltw4ivtb.dkim.amazonses.com"]
}

# ──────────────────────────────────────────
# SES — Domain Identity
# ──────────────────────────────────────────
resource "aws_ses_domain_identity" "nelasbakery" {
  domain = "nelasbakery.com"
}

resource "aws_ses_domain_dkim" "nelasbakery" {
  domain = aws_ses_domain_identity.nelasbakery.domain
}

# ──────────────────────────────────────────
# S3 — Email Storage Bucket
# ──────────────────────────────────────────
resource "aws_s3_bucket" "email_storage" {
  bucket = "${var.app_name}-email-storage-${random_id.suffix.hex}"

  tags = {
    Name = "${var.app_name}-email-storage"
  }
}

resource "aws_s3_bucket_public_access_block" "email_storage" {
  bucket                  = aws_s3_bucket.email_storage.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "email_storage" {
  bucket = aws_s3_bucket.email_storage.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ses.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.email_storage.arn}/*"
      Condition = {
        StringEquals = {
          "aws:Referer" = "380821404208"
        }
      }
    }]
  })
}

# ──────────────────────────────────────────
# IAM — Lambda Execution Role
# ──────────────────────────────────────────
resource "aws_iam_role" "lambda_role" {
  name = "${var.app_name}-lambda-email-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.app_name}-lambda-email-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.email_storage.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ses:SendRawEmail"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# ──────────────────────────────────────────
# Lambda — Email Forwarding Function
# ──────────────────────────────────────────
resource "aws_lambda_function" "email_forwarder" {
  filename         = "lambda/email_forwarder.zip"
  function_name    = "${var.app_name}-email-forwarder"
  role             = aws_iam_role.lambda_role.arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  source_code_hash = filebase64sha256("lambda/email_forwarder.zip")

  environment {
    variables = {
      FORWARD_TO    = "nelasbakeryofficial@gmail.com"
      FROM_EMAIL    = "orders@nelasbakery.com"
      EMAIL_BUCKET  = aws_s3_bucket.email_storage.bucket
    }
  }
}

resource "aws_lambda_permission" "ses_invoke" {
  statement_id  = "AllowSESInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.email_forwarder.function_name
  principal     = "ses.amazonaws.com"
  source_account = "380821404208"
}

# ──────────────────────────────────────────
# SES — Receipt Rule Set and Rule
# ──────────────────────────────────────────
resource "aws_ses_receipt_rule_set" "nelasbakery" {
  rule_set_name = "nelasbakery-rules"
}

resource "aws_ses_active_receipt_rule_set" "nelasbakery" {
  rule_set_name = aws_ses_receipt_rule_set.nelasbakery.rule_set_name
}

resource "aws_ses_receipt_rule" "forward_orders" {
  name          = "forward-to-gmail"
  rule_set_name = aws_ses_receipt_rule_set.nelasbakery.rule_set_name
  recipients    = ["orders@nelasbakery.com"]
  enabled       = true
  scan_enabled  = true

  s3_action {
    bucket_name = aws_s3_bucket.email_storage.bucket
    position    = 1
  }

  lambda_action {
    function_arn    = aws_lambda_function.email_forwarder.arn
    invocation_type = "Event"
    position        = 2
  }
}
