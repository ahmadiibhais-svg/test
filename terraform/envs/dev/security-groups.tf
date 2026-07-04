# Tier security groups — the least-privilege chain (CLAUDE.md). They live at the
# root (not in a module) because they are exactly the wiring BETWEEN modules.
# Chain link #2: only the ALB may talk to front-end, and only on its port.
resource "aws_security_group" "frontend" {
  name        = "sockshop-frontend-sg"
  description = "front-end tasks: 8079 from the ALB only"
  vpc_id      = module.network.vpc_id

  ingress {
    description     = "front-end port from the ALB SG only (identity, not IPs)"
    from_port       = 8079
    to_port         = 8079
    protocol        = "tcp"
    security_groups = [module.alb.alb_sg_id] # SG-as-source: the NetworkPolicy podSelector move
  }

  egress {
    description = "All outbound (chain is enforced on ingress)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sockshop-frontend-sg" }
}

# Chain link #3: backends accept 80 from front-end AND from each other.
# self = true covers every backend->backend pair (orders -> carts/user/payment/
# shipping) in one line — membership-based, like a NetworkPolicy selecting its own pods.
resource "aws_security_group" "backend" {
  name        = "sockshop-backend-sg"
  description = "backend services: 80 from front-end and from each other"
  vpc_id      = module.network.vpc_id

  ingress {
    description     = "service port from front-end (catalogue/user/carts/orders calls)"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend.id]
  }

  ingress {
    description = "service port between backends (orders to carts/user/payment/shipping)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sockshop-backend-sg" }
}

# Chain link #4: the data tier accepts only its exact protocols from its exact clients.
resource "aws_security_group" "data" {
  name        = "sockshop-data-sg"
  description = "data tier: mongo/amqp from backends; redis from front-end"
  vpc_id      = module.network.vpc_id

  ingress {
    description     = "MongoDB from backends (carts/orders/user to their dbs)"
    from_port       = 27017
    to_port         = 27017
    protocol        = "tcp"
    security_groups = [aws_security_group.backend.id]
  }

  ingress {
    description     = "AMQP from backends (shipping/queue-master to rabbitmq)"
    from_port       = 5672
    to_port         = 5672
    protocol        = "tcp"
    security_groups = [aws_security_group.backend.id]
  }

  ingress {
    description     = "Redis from front-end (session-db session store, D4/D11 amendment)"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sockshop-data-sg" }
}

# Chain link #5: RDS accepts MySQL from backends only (catalogue is its one real client).
resource "aws_security_group" "rds" {
  name        = "sockshop-rds-sg"
  description = "RDS MySQL: 3306 from backends only"
  vpc_id      = module.network.vpc_id

  ingress {
    description     = "MySQL from backends (catalogue)"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.backend.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sockshop-rds-sg" }
}
