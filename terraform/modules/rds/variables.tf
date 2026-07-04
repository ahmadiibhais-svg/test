variable "project" {
  description = "Prefix for names and the SSM parameter path."
  type        = string
  default     = "sockshop"
}

variable "subnet_ids" {
  description = "Private subnets only — RDS is never publicly reachable (locked)."
  type        = list(string)
}

variable "security_group_ids" {
  description = "rds-sg: 3306 from backend-sg only (chain link 5, D11)."
  type        = list(string)
}

variable "db_name" {
  description = "Database created at launch. socksdb = what catalogue's DSN expects (SERVICES.md)."
  type        = string
  default     = "socksdb"
}

variable "username" {
  description = <<-EOT
    Master username. catalogue_user matches the upstream DSN convention
    (helm chart), so the assembled DSN reads exactly like the original.
    Prod note for docs: app user would be separate from master.
  EOT
  type        = string
  default     = "catalogue_user"
}

variable "instance_class" {
  description = "Smallest viable (cost guardrail): db.t4g.micro (2 vCPU burstable Graviton, 1GB)."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "GB. 20 is the gp3 floor — dump.sql is under 1MB."
  type        = number
  default     = 20
}

variable "multi_az" {
  description = <<-EOT
    THE demo-day variable (locked decision): false while building (halves RDS cost),
    flipped to true for the final demo to show a standby in the second AZ.
  EOT
  type        = bool
  default     = false
}
