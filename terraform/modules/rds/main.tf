resource "random_password" "master" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.project}/rds/master-password"
  type  = "SecureString"
  value = random_password.master.result
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.project}-rds"
  subnet_ids = var.subnet_ids
}

#tfsec:ignore:aws-rds-specify-backup-retention -- accepted 2026-07-07: retention 0 is DELIBERATE (nightly destroy, D-notes below); prod >= 7 days in docs
#tfsec:ignore:AVD-AWS-0177 -- accepted 2026-07-07: deletion protection (rego check aws0177) would break the nightly destroy ritual (D14)
#tfsec:ignore:aws-rds-enable-iam-auth -- accepted 2026-07-07: catalogue's 2017 driver speaks password auth only (see auth-plugin note above)
#tfsec:ignore:aws-rds-enable-performance-insights -- accepted 2026-07-07: demo-scale db.t4g.micro; PI listed as prod tuning aid in docs
resource "aws_db_instance" "this" {
  identifier     = "${var.project}-catalogue-db"
  engine         = "mysql"
  engine_version = "8.0"

  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.username
  password = random_password.master.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = var.security_group_ids

  multi_az            = var.multi_az
  publicly_accessible = false

  skip_final_snapshot     = true
  backup_retention_period = 0
  #tfsec:ignore:AVD-AWS-0177 -- accepted 2026-07-07: deletion protection would break the nightly destroy ritual (D14)
  deletion_protection = false
  apply_immediately   = true
}

resource "aws_ssm_parameter" "catalogue_dsn" {
  name  = "/${var.project}/catalogue/dsn"
  type  = "SecureString"
  value = "${var.username}:${random_password.master.result}@tcp(${aws_db_instance.this.endpoint})/${var.db_name}"
}
