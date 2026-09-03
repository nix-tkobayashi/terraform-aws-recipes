output "account_id" {
  description = "Security Hub account resource id (the AWS account id)"
  value       = aws_securityhub_account.this.id
}
