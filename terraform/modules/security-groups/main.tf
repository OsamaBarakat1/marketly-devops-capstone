# Four tiers, each opening only what the tier in front of it needs.
# The ALB is the single place that accepts traffic from the internet;
# everything behind it accepts traffic only from the group in front.
#
# Rules are separate resources rather than inline blocks because alb-sg and
# k3s-sg reference each other, and inline blocks would form a dependency
# cycle. Note also that Terraform does not keep AWS's implicit allow-all
# egress rule, so every egress path below is deliberate.

# --- ALB: the only internet-facing group ---

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "Public entry point. Accepts HTTP/HTTPS from the internet."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from anywhere, for when a certificate is attached"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# The ALB only ever talks to the cluster's NodePort, so its egress is scoped
# to that instead of the usual allow-all.
resource "aws_vpc_security_group_egress_rule" "alb_to_nodes" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to the ingress NodePort on cluster nodes"
  referenced_security_group_id = aws_security_group.k3s.id
  from_port                    = var.ingress_nodeport
  to_port                      = var.ingress_nodeport
  ip_protocol                  = "tcp"
}

# --- k3s nodes: reachable from the ALB only ---

resource "aws_security_group" "k3s" {
  name        = "${var.name_prefix}-k3s-sg"
  description = "Control-plane and worker nodes. No public ingress."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-k3s-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "k3s_from_alb" {
  security_group_id            = aws_security_group.k3s.id
  description                  = "Ingress NodePort, from the load balancer only"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.ingress_nodeport
  to_port                      = var.ingress_nodeport
  ip_protocol                  = "tcp"
}

# Node-to-node traffic. Self-referencing rules match only instances that
# carry this same group, so these ports are never exposed beyond the cluster.
resource "aws_vpc_security_group_ingress_rule" "k3s_api" {
  security_group_id            = aws_security_group.k3s.id
  description                  = "Kubernetes API, for agents joining the server"
  referenced_security_group_id = aws_security_group.k3s.id
  from_port                    = 6443
  to_port                      = 6443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "k3s_flannel" {
  security_group_id            = aws_security_group.k3s.id
  description                  = "Flannel VXLAN, which carries all pod-to-pod traffic"
  referenced_security_group_id = aws_security_group.k3s.id
  from_port                    = 8472
  to_port                      = 8472
  ip_protocol                  = "udp"
}

resource "aws_vpc_security_group_ingress_rule" "k3s_kubelet" {
  security_group_id            = aws_security_group.k3s.id
  description                  = "Kubelet metrics, required by metrics-server for the HPA"
  referenced_security_group_id = aws_security_group.k3s.id
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
}

# Outbound is unrestricted so nodes can pull images from ECR and reach the
# SSM endpoints. It leaves through the NAT instance, so nothing inbound
# becomes possible as a result.
resource "aws_vpc_security_group_egress_rule" "k3s_all" {
  security_group_id = aws_security_group.k3s.id
  description       = "Outbound via the NAT instance"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- RDS: reachable from the cluster only ---

resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds-sg"
  description = "PostgreSQL, reachable only from cluster nodes."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-rds-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_k3s" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL from cluster nodes only"
  referenced_security_group_id = aws_security_group.k3s.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# No egress rule at all. A database has no reason to open connections
# outward, and responses to inbound connections flow regardless because
# security groups are stateful.

# --- NAT instance: traffic from inside the VPC only ---

resource "aws_security_group" "nat" {
  name        = "${var.name_prefix}-nat-sg"
  description = "NAT instance. Forwards outbound traffic for private subnets."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-nat-sg"
  }
}

# Scoped to the VPC CIDR rather than a security group: this is routed
# traffic being forwarded, so it arrives with the original instance's
# private address rather than a group membership the rule could match on.
resource "aws_vpc_security_group_ingress_rule" "nat_from_vpc" {
  security_group_id = aws_security_group.nat.id
  description       = "Any traffic originating inside the VPC"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "nat_all" {
  security_group_id = aws_security_group.nat.id
  description       = "Outbound to the internet on behalf of private subnets"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
