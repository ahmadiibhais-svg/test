# Network module — implements the L1 mental model (see EXPLANATIONS.md):
# a sealed VPC, two failure domains, an inbound door (IGW), an outbound-only
# door (NAT, single — documented cost trade-off), and the free S3 bypass.

# ---------------------------------------------------------------- the sealed box
resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both true so resources inside get/resolve DNS names — Service Connect
  # discovery and the RDS endpoint hostname depend on VPC DNS working.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name}-vpc" }
}

# ------------------------------------------------- inbound door (public subnets)
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-igw" }
}

# ---------------------------------------------------------------------- subnets
# Written explicitly (no loop): at n=2 AZs, four named blocks are more readable
# and defensible than a clever loop. var.azs[0] = list indexing — first element.
resource "aws_subnet" "public_a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidrs[0]
  availability_zone = var.azs[0]

  # NOTE: map_public_ip_on_launch stays at its default (false) even here.
  # Nothing in public subnets needs an automatic public IP: the ALB manages its
  # own addresses and the NAT uses an EIP. Least surface, even where "public".
  tags = { Name = "${var.name}-public-a" }
}

resource "aws_subnet" "public_b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidrs[1]
  availability_zone = var.azs[1]

  tags = { Name = "${var.name}-public-b" }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[0]
  availability_zone = var.azs[0]

  tags = { Name = "${var.name}-private-a" }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[1]
  availability_zone = var.azs[1]

  tags = { Name = "${var.name}-private-b" }
}

# -------------------------------------------------- outbound-only door (the NAT)
# A NAT gateway needs a static public IP of its own — an Elastic IP.
# 💰 public IPv4 addresses bill ~$0.005/hr; the NAT itself ~$0.045/hr.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${var.name}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id # single NAT in AZ-a — documented trade-off

  # First explicit depends_on in this repo: normally ordering comes from
  # references (L2), but NAT never *references* the IGW — yet it cannot function
  # until the VPC has one attached. depends_on states a dependency the reference
  # graph can't see.
  depends_on = [aws_internet_gateway.this]

  tags = { Name = "${var.name}-nat" }
}

# ------------------------------------------------------------------ route tables
# THE defining fact of public vs private: it's not a checkbox on the subnet,
# it's which route table the subnet is associated with.

# Public = "unknown destinations exit via the Internet Gateway" (two-way door).
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name}-public-rt" }
}

# Private = "unknown destinations exit via the NAT" (outbound-only door).
# One shared table because there is one NAT; the multi-NAT production upgrade
# would split this into one table per AZ, each pointing at its local NAT.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = { Name = "${var.name}-private-rt" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# ------------------------------------------------------- the free S3 bypass (L1)
# Gateway endpoint = a route-table entry, not a device. Attached to the PRIVATE
# table: that's where the image-layer traffic originates. Free, so the heaviest
# traffic class (ECR layers from S3) never pays the NAT toll.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.name}-s3-endpoint" }
}
