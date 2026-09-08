# A self-managed k3s cluster: one control-plane instance and an Auto Scaling
# Group of agents. There is no managed control plane and no SSH — nodes are
# reached through Session Manager and join each other using a token passed
# via SSM Parameter Store.

data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# --- control plane ---

resource "aws_instance" "server" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.server_instance_type
  subnet_id              = var.private_subnet_ids[0]
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.server.name

  # Private subnet, so no public address exists to attack.
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/templates/control-plane-user-data.sh.tpl", {
    token_parameter_name = local.token_parameter_name
    aws_region           = var.aws_region
    ingress_nodeport     = var.ingress_nodeport
  })

  user_data_replace_on_change = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  tags = {
    Name = "${var.name_prefix}-k3s-server"
    Role = "k3s-server"
  }
}

# --- workers ---

resource "aws_launch_template" "agent" {
  name_prefix   = "${var.name_prefix}-k3s-agent-"
  image_id      = data.aws_ssm_parameter.al2023.value
  instance_type = var.agent_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.agent.name
  }

  vpc_security_group_ids = [var.security_group_id]

  user_data = base64encode(templatefile("${path.module}/templates/worker-user-data.sh.tpl", {
    token_parameter_name = local.token_parameter_name
    aws_region           = var.aws_region
    server_url           = "https://${aws_instance.server.private_ip}:6443"
  }))

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = 20
      volume_type = "gp3"
      encrypted   = true
    }
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.name_prefix}-k3s-agent"
      Role = "k3s-agent"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "agents" {
  name_prefix         = "${var.name_prefix}-k3s-agents-"
  vpc_zone_identifier = var.private_subnet_ids
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity

  launch_template {
    id      = aws_launch_template.agent.id
    version = "$Latest"
  }

  # EC2 health checks only notice a dead instance, not a node that failed to
  # join the cluster. Good enough here; a production build would report
  # cluster membership back as a custom health check.
  health_check_type         = "EC2"
  health_check_grace_period = 300

  # Replace nodes one at a time on a launch template change, so the cluster
  # never loses every worker at once.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-k3s-agent"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
