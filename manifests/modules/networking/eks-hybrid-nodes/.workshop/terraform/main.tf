data "aws_availability_zones" "available" {}

locals {
  remote_node_cidr    = cidrsubnet(var.remote_network_cidr, 8, 0)
  remote_pod_cidr     = "172.16.0.0/16"

  remote_node_azs = slice(data.aws_availability_zones.available.names, 0, 3)

  name               = "${var.addon_context.eks_cluster_id}-remote"
}

# Primary VPC created for the EKS Cluster
data "aws_vpc" "primary" {
  tags = {
    created-by = "eks-workshop-v2"
    env        = var.addon_context.eks_cluster_id
  }
}

# Look up "primary" vpc subnet
data "aws_subnets" "private" {
  tags = {
    created-by = "eks-workshop-v2"
    env        = var.addon_context.eks_cluster_id
  }

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.primary.id]
  }

  filter {
    name   = "tag:Name"
    values = ["*Private*"]
  }
}

################################################################################
# Remote VPC
################################################################################

# Create VPC in remote region
resource "aws_vpc" "remote" {

  cidr_block           = var.remote_network_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "${local.name}-vpc"
  })
}

# Create public subnets in remote VPC
resource "aws_subnet" "remote_public" {
  #count = 3

  vpc_id            = aws_vpc.remote.id
  
  # This will split 10.52.1.0/24 into three /26 subnets (10.52.1.0/26, 10.52.1.64/26, 10.52.1.128/26)
  cidr_block        = local.remote_node_cidr
  availability_zone = local.remote_node_azs[0]

  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${local.name}-public"
  })
}

# Internet Gateway for remote VPC
resource "aws_internet_gateway" "remote" {
  vpc_id = aws_vpc.remote.id

  tags = merge(var.tags, {
    Name = "${local.name}-igw"
  })
}

# Route table for remote public subnets
resource "aws_route_table" "remote_public" {
  vpc_id = aws_vpc.remote.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.remote.id
  }

  tags = merge(var.tags, {
    Name = "${local.name}-public-rt"
  })
}

# Associate route table with public subnets
resource "aws_route_table_association" "remote_public" {
  
  subnet_id      = aws_subnet.remote_public.id
  route_table_id = aws_route_table.remote_public.id
}

################################################################################
# Psuedo Hybrid Node
# Demonstration only - AWS EC2 instances are not supported for EKS Hybrid nodes
################################################################################

module "key_pair" {
  source  = "terraform-aws-modules/key-pair/aws"
  version = "~> 2.0"

  key_name           = "hybrid-node"
  create_private_key = true

  tags = var.tags
}

resource "local_file" "key_pem" {
  content         = module.key_pair.private_key_pem
  filename        = "${path.cwd}/environment/private-key.pem"
  file_permission = "0600"
}

# Define the security group for the hybrid nodes
resource "aws_security_group" "hybrid_nodes" {
  name        = "hybrid-nodes-sg"
  description = "Security group for hybrid EKS nodes"
  vpc_id      = aws_vpc.remote.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.primary.cidr_block]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.primary.cidr_block]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.remote_pod_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

module "hybrid_node" {
  depends_on = [aws_ec2_transit_gateway.tgw, aws_internet_gateway.remote]
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 5.7.1"

  ami_ssm_parameter = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"

  instance_type = "m5.large"
  subnet_id     = aws_subnet.remote_public.id
  vpc_security_group_ids = [aws_security_group.hybrid_nodes.id]
  key_name      = module.key_pair.key_pair_name

  root_block_device = [{
    volume_size = 100
    volume_type = "gp3"
    delete_on_termination = true
  }]

  source_dest_check = false

  user_data = <<-EOF
              #cloud-config
              package_update: true
              packages:
                - unzip

              runcmd:
                - cd /tmp
                - echo "Installing AWS CLI..."
                - curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
                - unzip awscliv2.zip
                - ./aws/install
                - rm awscliv2.zip
                - rm -rf aws/
                - echo "Verifying AWS CLI installation..."
                - aws --version
                
                - echo "Downloading nodeadm..."
                - curl -OL 'https://hybrid-assets.eks.amazonaws.com/releases/latest/bin/linux/amd64/nodeadm'
                - chmod +x nodeadm
                
                - echo "Moving nodeadm to /usr/local/bin"
                - mv nodeadm /usr/local/bin/

                - echo "Verifying installations..."
                - nodeadm --version
              EOF
  tags = merge(var.tags, {
    Name = "${var.addon_context.eks_cluster_id}-hybrid-node-01"
  })
}

################################################################################
# Hybrid Networking
################################################################################

# Create Transit Gateway
resource "aws_ec2_transit_gateway" "tgw" {
 
  description = "Transit Gateway for EKS Workshop Hybrid setup"

  auto_accept_shared_attachments = "enable"
  
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"
  
  tags = merge(var.tags, {
    Name = "${var.addon_context.eks_cluster_id}-tgw"
  })
}

# Create Transit Gateway VPC Attachment for remote VPC
resource "aws_ec2_transit_gateway_vpc_attachment" "remote" {
  #provider = aws.remote

  subnet_ids         = [aws_subnet.remote_public.id]
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  vpc_id            = aws_vpc.remote.id
  
  dns_support = "enable"
  
  tags = merge(var.tags, {
    Name = "${var.addon_context.eks_cluster_id}-remote-tgw-attachment"
  })
}

data "aws_subnets" "cluster_public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.primary.id]
  }

  tags = {
    created-by = "eks-workshop-v2"
    env        = var.addon_context.eks_cluster_id
  }

  filter {
    name   = "tag:Name"
    values = ["*Public*"]
  }
}

# Attach the main EKS VPC to TGW
resource "aws_ec2_transit_gateway_vpc_attachment" "main" {
  subnet_ids         = data.aws_subnets.cluster_public.ids
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  vpc_id            = data.aws_vpc.primary.id
  
  dns_support = "enable"
  
  tags = merge(var.tags, {
    Name = "${var.addon_context.eks_cluster_id}-main-tgw-attachment"
  })
}

# Add route in remote VPC route table to reach main VPC
resource "aws_route" "remote_to_main" {
  route_table_id         = aws_route_table.remote_public.id
  destination_cidr_block = data.aws_vpc.primary.cidr_block
  transit_gateway_id     = aws_ec2_transit_gateway.tgw.id
}

data "aws_route_tables" "cluster_vpc_routetable" {
  vpc_id    = data.aws_vpc.primary.id
  tags = {
    created-by = "eks-workshop-v2"
    env        = var.addon_context.eks_cluster_id
  }

}

# Add route in main VPC route tables to reach remote VPC
resource "aws_route" "main_to_remote" {
  count                     = length(data.aws_route_tables.cluster_vpc_routetable.ids)
  route_table_id            = tolist(data.aws_route_tables.cluster_vpc_routetable.ids)[count.index]
  
  destination_cidr_block    = var.remote_network_cidr
  transit_gateway_id        = aws_ec2_transit_gateway.tgw.id
}


###### HYBRID ROLE #####

module "eks_hybrid_node_role" {
  source  = "terraform-aws-modules/eks/aws//modules/hybrid-node-role"
  version = "~> 20.31"
  name = "${var.eks_cluster_id}-hybrid-node-role"
  policy_name = "${var.eks_cluster_id}-hybrid-node-policy"
  tags = var.tags
}

resource "aws_eks_access_entry" "remote" {
  cluster_name    = var.eks_cluster_id
  principal_arn = module.eks_hybrid_node_role.arn
  type          = "HYBRID_LINUX"
  tags = var.tags
}

#resource "aws_route" "route_to_pod" {
#  route_table_id            = aws_route_table.remote_public.id
#  destination_cidr_block    = local.remote_pod_cidr
#  network_interface_id      = module.hybrid_node.primary_network_interface_id
#}

