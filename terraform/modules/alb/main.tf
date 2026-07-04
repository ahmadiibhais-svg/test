# ALB module — the inbound door (L1): internet → ALB → front-end, nothing else.
# Three parts map to K8s roles: aws_lb = the Ingress controller appliance,
# aws_lb_target_group = EndpointSlice + readinessProbe, aws_lb_listener = the rule.

# First link of the least-privilege SG chain (CLAUDE.md):
#   internet --80--> alb-sg --8079--> frontend-sg --> backend-sg --> data/rds-sg
# SGs are STATEFUL (replies auto-allowed; rules describe who may INITIATE) and can
# name other SGs as source — identity-based, like a NetworkPolicy podSelector.
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb-sg"
  description = "ALB: HTTP from the internet"
  vpc_id      = var.vpc_id

  # The ONE place "from anywhere" is correct: this is the public front door.
  ingress {
    description = "HTTP from the internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Chain is enforced on ingress (the initiating direction); egress stays open —
  # standard pattern, keeps rules readable as "who may start a conversation".
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-alb-sg" }
}

resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false # public-facing — the only public entry to the app
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids # >= 2 AZs required by ALBs

  tags = { Name = "${var.name}-alb" }
}

resource "aws_lb_target_group" "front_end" {
  name     = "${var.name}-front-end-tg"
  vpc_id   = var.vpc_id
  port     = var.target_port
  protocol = "HTTP"

  # Fargate/awsvpc gives every task its own ENI + private IP (pod-IPs, literally),
  # so the ALB targets IPs. "instance" is the NodePort-era pattern — no instances here.
  target_type = "ip"

  # Connection draining: stop NEW traffic instantly on removal, give in-flight
  # requests 30s to finish (default 300s = pointlessly slow rollouts for a demo).
  deregistration_delay = 30

  # The readinessProbe, ALB edition: fail 3x -> pulled from rotation.
  health_check {
    path                = var.health_check_path
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200-299"
  }

  tags = { Name = "${var.name}-front-end-tg" }
}

# The Ingress rule: on :80, forward everything to the front-end group.
# (HTTPS/ACM is a documented production upgrade, not built in the time box.)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.front_end.arn
  }
}
