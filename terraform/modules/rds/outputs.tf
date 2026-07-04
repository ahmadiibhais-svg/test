output "endpoint" {
  description = "host:port of the instance (the seeding task needs it)."
  value       = aws_db_instance.this.endpoint
}

output "address" {
  description = "Hostname only (no port)."
  value       = aws_db_instance.this.address
}

output "db_name" {
  description = "Database name (socksdb)."
  value       = aws_db_instance.this.db_name
}

output "username" {
  description = "Master username (catalogue_user)."
  value       = aws_db_instance.this.username
}

output "password_parameter_arn" {
  description = "SSM SecureString ARN of the master password (seed task injects it)."
  value       = aws_ssm_parameter.db_password.arn
}

output "dsn_parameter_arn" {
  description = "SSM SecureString ARN of catalogue's complete DSN (catalogue injects it)."
  value       = aws_ssm_parameter.catalogue_dsn.arn
}
