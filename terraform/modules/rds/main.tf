# RDS module — catalogue-db replaced by managed MySQL (locked decision).
# Implements D10 end-to-end: generated password -> SSM SecureString -> injected
# at task launch. Plaintext never in code, task defs, or git (state caveat: D10).

# random_password is a RESOURCE from the hashicorp/random provider: "creating" it
# generates the value once and remembers it in state (D10 caveat lives here).
# special = false (alphanumeric only) ON PURPOSE, satisfying two charsets at once:
#   - RDS forbids / @ " and spaces in master passwords
#   - the Go MySQL DSN (user:pass@tcp(...)) would mis-parse : / @ in a password
resource "random_password" "master" {
  length  = 32
  special = false
}

# D10: the password at rest — encrypted with KMS, free standard tier.
resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.project}/rds/master-password"
  type  = "SecureString"
  value = random_password.master.result
}

# Which subnets RDS may place instances in (and where a multi-AZ standby lands:
# the OTHER private subnet). Placement contract, like a nodeSelector over subnets.
resource "aws_db_subnet_group" "this" {
  name       = "${var.project}-rds"
  subnet_ids = var.subnet_ids
}

# Compatibility note (defense story): MySQL 8's default auth plugin is
# caching_sha2_password; catalogue:0.3.5 embeds a ~2017 Go MySQL driver that
# predates it and would fail the handshake. First attempt: force
# default_authentication_plugin=mysql_native_password via a parameter group —
# REJECTED by AWS at apply time ("cannot be modified" on current 8.0 engines).
# Actual fix: the SEED task (modern mysql:8 client, unaffected) runs
# ALTER USER ... IDENTIFIED WITH mysql_native_password before catalogue ever
# connects. Compatibility handled at the USER level, not the server level.
resource "aws_db_instance" "this" {
  identifier     = "${var.project}-catalogue-db"
  engine         = "mysql"
  engine_version = "8.0"

  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true # free, standard posture

  db_name  = var.db_name
  username = var.username
  password = random_password.master.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = var.security_group_ids

  multi_az            = var.multi_az # false in dev; true for demo day (locked)
  publicly_accessible = false        # locked: reachable only via rds-sg inside the VPC

  # Destroyability decisions (nightly destroy is a feature, not neglect):
  skip_final_snapshot     = true # else destroy blocks demanding a snapshot name
  backup_retention_period = 0    # no automated backups in dev (prod: >= 7 days — docs)
  deletion_protection     = false
  apply_immediately       = true
}

# D10, catalogue's half: the COMPLETE DSN as one SecureString, assembled here where
# all parts are known. endpoint already includes ":3306" (host:port attribute).
# Delivery (review-workflow catch): catalogue reads -DSN as a FLAG only and ECS does
# no $(VAR) substitution in command — so SSM injects this as env var DSN, and the
# container launches via sh -c 'exec /app -port=80 -DSN="$DSN"' (wired in the
# catalogue unit; needs the ecs-service entrypoint/command extension).
resource "aws_ssm_parameter" "catalogue_dsn" {
  name  = "/${var.project}/catalogue/dsn"
  type  = "SecureString"
  value = "${var.username}:${random_password.master.result}@tcp(${aws_db_instance.this.endpoint})/${var.db_name}"
}
