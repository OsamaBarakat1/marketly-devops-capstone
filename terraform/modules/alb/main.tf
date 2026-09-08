# The single public entry point. Traffic path:
#   internet -> ALB -> NodePort on any k3s node -> Traefik -> Service -> pod
#
# Traefik does the path-based routing to the four components, so the ALB
# needs only one target group and one listener rule.

# tfsec:ignore:aws-elb-alb-not-public This load balancer is the application's public entry point; being reachable is its purpose.
resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.security_group_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = false

  # Rejects malformed headers instead of passing them to the cluster, which
  # is what enables request smuggling against whatever sits behind.
  drop_invalid_header_fields = true

  idle_timeout = 60

  tags = {
    Name = "${var.name_prefix}-alb"
  }
}

resource "aws_lb_target_group" "nodes" {
  name     = "${var.name_prefix}-nodes-tg"
  port     = var.ingress_nodeport
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  # Instance targets, not IP targets: the ALB sends to the NodePort on the
  # node itself, and Traefik forwards from there. That keeps the ALB unaware
  # of pod addresses, which change constantly.
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3

    # Traefik answers 404 for any path it has no route for, which is what a
    # healthy but not-yet-configured cluster returns. Accepting 404 means a
    # node counts as healthy once Traefik is up, rather than only after the
    # Ingress exists — otherwise the first deploy has nowhere to land.
    matcher = "200-404"
  }

  # Long enough for in-flight requests to finish during a rolling node
  # replacement, short enough not to stall a teardown.
  deregistration_delay = 30

  lifecycle {
    create_before_destroy = true
  }
}

# New workers register themselves as the ASG scales, so nothing has to be
# added to the load balancer by hand.
resource "aws_autoscaling_attachment" "agents" {
  autoscaling_group_name = var.autoscaling_group_name
  lb_target_group_arn    = aws_lb_target_group.nodes.arn
}

# The control plane runs pods too and carries the same NodePort, so it is
# registered directly. It is not in the ASG, so it needs its own attachment.
resource "aws_lb_target_group_attachment" "server" {
  target_group_arn = aws_lb_target_group.nodes.arn
  target_id        = var.server_instance_id
  port             = var.ingress_nodeport
}

# tfsec:ignore:aws-elb-http-not-used HTTPS needs a certificate, which needs a domain. The free tier provides neither, and an ALB's generated DNS name cannot hold an ACM certificate. Documented as a known limitation: with a domain, this becomes a redirect to a 443 listener and COOKIE_SECURE is enabled in auth-service.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # Plain HTTP because the free tier gives no certificate and the ALB's
  # generated DNS name cannot have one. With a domain and an ACM
  # certificate this would redirect to a 443 listener instead, and
  # COOKIE_SECURE would be turned on in auth-service.
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nodes.arn
  }
}
