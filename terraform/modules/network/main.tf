/**
 * Three-tier VPC:
 *   public       ALB + NAT gateways. Only tier with a route to the Internet Gateway.
 *   private_app  ECS tasks (and VPC-attached Lambdas). Egress via NAT / VPC endpoints.
 *   private_data RDS + RDS Proxy. No route to the internet at all, in either direction.
 *
 * Address plan for a /16 (e.g. 10.20.0.0/16):
 *   public       /24 per AZ  -> 10.20.0.0/24, 10.20.1.0/24, 10.20.2.0/24
 *   private_app  /20 per AZ  -> 10.20.16.0/20, 10.20.32.0/20, 10.20.48.0/20  (4,091 IPs each:
 *                               every Fargate task consumes one ENI/IP, so this tier is sized
 *                               for 10x growth)
 *   private_data /24 per AZ  -> 10.20.200.0/24, 10.20.201.0/24, 10.20.202.0/24
 */

data "aws_region" "current" {}

locals {
  # AZs are pinned explicitly instead of read from aws_availability_zones: if an AZ
  # were reported impaired (or a new one appeared), a data-source lookup would shift
  # every subnet index and plan to destroy and recreate the network.
  azs      = var.availability_zones
  az_count = length(var.availability_zones)

  public_cidrs = [for i in range(local.az_count) : cidrsubnet(var.cidr_block, 8, i)]
  app_cidrs    = [for i in range(local.az_count) : cidrsubnet(var.cidr_block, 4, i + 1)]
  data_cidrs   = [for i in range(local.az_count) : cidrsubnet(var.cidr_block, 8, 200 + i)]

  nat_gateway_count = var.single_nat_gateway ? 1 : local.az_count
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name }
}

# The default security group allows all traffic between its members; strip every rule
# so nothing can accidentally rely on it.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-default-do-not-use" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = local.public_cidrs[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${var.name}-public-${local.azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "private_app" {
  count = local.az_count

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.app_cidrs[count.index]

  tags = { Name = "${var.name}-app-${local.azs[count.index]}", Tier = "private-app" }
}

resource "aws_subnet" "private_data" {
  count = local.az_count

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.data_cidrs[count.index]

  tags = { Name = "${var.name}-data-${local.azs[count.index]}", Tier = "private-data" }
}

resource "aws_eip" "nat" {
  count  = local.nat_gateway_count
  domain = "vpc"
  tags   = { Name = "${var.name}-nat-${local.azs[count.index]}" }
}

# One NAT gateway per AZ in production so an AZ failure cannot cut egress for the
# surviving AZs; a single NAT gateway in dev/staging to save ~$33/month per gateway.
resource "aws_nat_gateway" "this" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${var.name}-${local.azs[count.index]}" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = local.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private_app" {
  count  = local.az_count
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-app-${local.azs[count.index]}" }
}

resource "aws_route" "private_app_nat" {
  count = local.az_count

  route_table_id         = aws_route_table.private_app[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "private_app" {
  count          = local.az_count
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app[count.index].id
}

# Data tier: local routes only.
resource "aws_route_table" "private_data" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-data" }
}

resource "aws_route_table_association" "private_data" {
  count          = local.az_count
  subnet_id      = aws_subnet.private_data[count.index].id
  route_table_id = aws_route_table.private_data.id
}

# --------------------------------------------------------------------------------------
# VPC endpoints: keep AWS API traffic (image pulls, logs, secrets) off the NAT gateway.
# This is both a security and a cost control (NAT data processing is $0.045/GB).
# --------------------------------------------------------------------------------------

# Gateway endpoint: free. ECR image layers are served from S3, so this alone removes
# most image-pull traffic from the NAT gateway.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(aws_route_table.private_app[*].id, [aws_route_table.private_data.id])
  tags              = { Name = "${var.name}-s3" }
}

resource "aws_security_group" "endpoints" {
  count = var.enable_interface_endpoints ? 1 : 0

  name        = "${var.name}-vpc-endpoints"
  description = "HTTPS from inside the VPC to AWS interface endpoints"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-vpc-endpoints" }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  count = var.enable_interface_endpoints ? 1 : 0

  security_group_id = aws_security_group.endpoints[0].id
  description       = "HTTPS from VPC"
  cidr_ipv4         = var.cidr_block
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : toset([])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.private_app[*].id
  security_group_ids  = [aws_security_group.endpoints[0].id]
  tags                = { Name = "${var.name}-${each.value}" }
}

# --------------------------------------------------------------------------------------
# VPC flow logs (rejected + accepted) for security investigations.
# --------------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "flow_logs" {
  #checkov:skip=CKV_AWS_338:Retention is set per environment (90 days in prod); long-term archive goes to S3 where compliance requires it
  count = var.enable_flow_logs ? 1 : 0

  name              = "/vpc/${var.name}/flow-logs"
  retention_in_days = var.flow_log_retention_days
  kms_key_id        = var.kms_key_arn
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name               = "${var.name}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

data "aws_iam_policy_document" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn             = aws_iam_role.flow_logs[0].arn
  max_aggregation_interval = 60
}
