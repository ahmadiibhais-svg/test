resource "aws_security_group" "alb" {
  name        = "${var.name}-alb-sg"
  description = "ALB: HTTP from the internet"
  vpc_id      = var.vpc_id

  #tfsec:ignore:aws-ec2-no-public-ingress-sgr -- accepted 2026-07-07: a public storefront's ALB admits the internet BY DESIGN (D11: the only 0.0.0.0/0 ingress in the system)
  ingress {
    description = "HTTP from the internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  #tfsec:ignore:aws-ec2-no-public-egress-sgr -- accepted 2026-07-07: chain-on-ingress design (D11); egress restriction adds no protection when ingress is identity-pinned
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-alb-sg" }
}

#tfsec:ignore:aws-elb-alb-not-public -- accepted 2026-07-07: a public storefront's LB is public; that is the requirement, not a finding
resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  drop_invalid_header_fields = true

  tags = { Name = "${var.name}-alb" }
}

resource "aws_lb_target_group" "front_end" {
  name     = "${var.name}-front-end-tg"
  vpc_id   = var.vpc_id
  port     = var.target_port
  protocol = "HTTP"

  target_type = "ip"

  deregistration_delay = 30

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

#tfsec:ignore:aws-elb-http-not-used -- accepted 2026-07-07: HTTPS needs a domain + ACM cert; documented as the FIRST production upgrade (docs: Production Scaling)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.front_end.arn
  }
}
