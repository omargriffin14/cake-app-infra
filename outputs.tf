output "backend_ec2_id" {
  value = aws_instance.backend.id
}

output "backend_ec2_private_ip" {
  value = aws_instance.backend.private_ip
}

output "frontend_s3_bucket" {
  value = aws_s3_bucket.frontend.bucket
}

output "cloudfront_url" {
  value = "https://${aws_cloudfront_distribution.frontend.domain_name}"
}

output "db_secret_arn" {
  value = aws_secretsmanager_secret.db_credentials.arn
}

output "nat_gateway_id" {
  value = aws_nat_gateway.main.id
}

output "uploads_bucket_name" {
  value = aws_s3_bucket.uploads.bucket
}

output "ses_email_identity" {
  value = aws_ses_email_identity.bakery.email
}

output "email_storage_bucket" {
  value = aws_s3_bucket.email_storage.bucket
}

output "lambda_function_name" {
  value = aws_lambda_function.email_forwarder.function_name
}
