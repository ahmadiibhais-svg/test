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
