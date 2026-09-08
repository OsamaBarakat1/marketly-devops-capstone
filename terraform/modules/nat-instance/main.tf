# A managed NAT Gateway bills per hour plus per GB and is not free-tier
# eligible. A t3.micro doing the same forwarding is, which is the whole
# reason this module exists instead of a two-line aws_nat_gateway.
#
# The trade-off is honest: this is a single instance with no redundancy. If
# it fails, private subnets lose outbound access until the ASG-free instance
# is replaced. A production build would run one NAT per AZ or accept the
# gateway's cost.

data "aws_ssm_parameter" "al2023" {
  # Tracks the current Amazon Linux 2023 image rather than pinning an AMI ID,
  # which would be region-specific and would go stale.
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "nat" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  associate_public_ip_address = true

  # The one setting that makes NAT work at all. EC2 normally drops packets
  # whose source or destination is not the instance itself, which is exactly
  # what forwarded traffic looks like.
  source_dest_check = false

  user_data = templatefile("${path.module}/templates/nat-user-data.sh.tpl", {
    vpc_cidr = var.vpc_cidr
  })

  # Replace the instance if the bootstrap script changes.
  user_data_replace_on_change = true

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens   = "required" # IMDSv2 only, closing the SSRF-to-credentials path
    http_endpoint = "enabled"
  }

  tags = {
    Name = "${var.name_prefix}-nat"
    Role = "nat"
  }
}

# The route that makes the private subnets private-but-connected: outbound
# traffic goes to this instance, and because nothing routes inbound to them,
# they stay unreachable from the internet.
resource "aws_route" "private_default" {
  count = length(var.private_route_table_ids)

  route_table_id         = var.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat.primary_network_interface_id
}

# A stable address, so replacing the instance does not change what the
# route points at from the outside world's perspective.
resource "aws_eip" "nat" {
  instance = aws_instance.nat.id
  domain   = "vpc"

  tags = {
    Name = "${var.name_prefix}-nat-eip"
  }
}
