# The network everything else sits inside. A subnet is public or private
# purely because of the route table attached to it — there is no "public
# subnet" resource type in AWS.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

# tfsec:ignore:aws-ec2-require-vpc-flow-logs-for-all-vpcs Flow logs bill for CloudWatch Logs ingestion and storage, which is outside the free-tier budget this project is constrained to. Worth enabling in any environment holding real traffic.
resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Required for RDS to hand out a resolvable endpoint hostname inside the VPC.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# The only path between the VPC and the public internet.
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# --- public subnets: ALB and the NAT instance ---

# tfsec:ignore:aws-ec2-no-public-ip-subnet Public IPs here are deliberate and confined to this tier: the ALB and the NAT instance are the only things in these subnets, and both must be internet-reachable for the private subnets to stay unreachable.
resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # The NAT instance and the ALB need to be addressable from the internet.
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-public-${local.azs[count.index]}"
    Tier = "public"
    # Lets a Kubernetes cloud controller discover these subnets for
    # internet-facing load balancers.
    "kubernetes.io/role/elb" = "1"
  }
}

# --- private subnets: k3s nodes and RDS ---

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # No public IPs. These instances reach the internet outbound through the
  # NAT instance and cannot be reached inbound at all.
  map_public_ip_on_launch = false

  tags = {
    Name                              = "${var.name_prefix}-private-${local.azs[count.index]}"
    Tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# --- routing ---

# Internet-bound traffic leaves through the gateway, which is what makes
# these subnets public.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Deliberately has no 0.0.0.0/0 route here. The nat-instance module adds one
# pointing at its network interface; defining it there keeps this module from
# depending on the instance and creating a cycle.
#
# One table per AZ: if a single table were shared and the NAT instance failed,
# every AZ would lose egress at once. Per-AZ tables also leave room to run a
# NAT per zone later without restructuring.
resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-private-rt-${local.azs[count.index]}"
  }
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
