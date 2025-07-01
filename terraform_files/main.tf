# Configuring the AWS provider
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
provider "aws" {
  region = var.region
}

# Creating a VPC with only public subnets
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "currency-converter-vpc"
    Environment = "production"
    Project     = "currency-converter"
  }
}

# Public subnets
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index}.0/24"
  map_public_ip_on_launch = true
  availability_zone = element(["${var.region}a", "${var.region}b"], count.index)

  tags = {
    Name        = "public-subnet-${count.index}"
    Environment = "production"
    Project     = "currency-converter"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "currency-converter-igw"
    Environment = "production"
    Project     = "currency-converter"
  }
}

# Route Table for public subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name        = "public-route-table"
    Environment = "production"
    Project     = "currency-converter"
  }
}

# Associate route table with public subnets
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = element(aws_subnet.public.*.id, count.index)
  route_table_id = aws_route_table.public.id
}

# Creating an IAM role for EC2 instances
resource "aws_iam_role" "ec2_role" {
  name = "currency-converter-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# Attaching policies to EC2 role
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ec2_eks_access" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "ec2_eks_worker" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "currency-converter-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# Security group for Jenkins controller
resource "aws_security_group" "jenkins_controller_sg" {
  name_prefix = "jenkins-controller-sg"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow HTTP for Jenkins"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Restrict to your IP in production
  }

  ingress {
    description = "Allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Restrict to your IP in production
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = "Jenkins"
    Project     = "currency-converter"
  }
}

# Security group for Jenkins agent, SonarQube, and EKS nodes
resource "aws_security_group" "agent_sonarqube_eks_sg" {
  name_prefix = "agent-sonarqube-eks-sg"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow HTTP for SonarQube"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Restrict to your IP in production
  }

  ingress {
    description = "Allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Restrict to your IP in production
  }

  ingress {
    description = "Allow Jenkins controller communication"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    security_groups = [aws_security_group.jenkins_controller_sg.id]
  }

  ingress {
    description = "Allow EKS node communication"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "Allow EKS API server"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Restrict to your IP in production
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = "Agent-SonarQube-EKS"
    Project     = "currency-converter"
  }
}

# EC2 instance for Jenkins controller
resource "aws_instance" "jenkins_controller" {
  ami                    = "ami-020cba7c55df1f615" # Ubuntu 20.04 LTS in us-east-1, verify latest
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.jenkins_controller_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_instance_profile.name
  associate_public_ip_address = true
  key_name               = "jenkins" # Replace with your EC2 key pair name

  # Root volume
  root_block_device {
    volume_size = 10
    volume_type = "gp3"
  }

  tags = {
    Name        = "jenkins-controller"
    Environment = "production"
    Project     = "currency-converter"
  }
}

# EC2 instance for Jenkins agent, SonarQube, Trivy, OWASP
resource "aws_instance" "agent_sonarqube" {
  ami                    = "ami-020cba7c55df1f615" # Ubuntu 20.04 LTS in us-east-1, verify latest
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.public[1].id
  vpc_security_group_ids = [aws_security_group.agent_sonarqube_eks_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_instance_profile.name
  associate_public_ip_address = true
  key_name               = "jenkins" # Replace with your EC2 key pair name

  # Root volume
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }
  

  tags = {
    Name        = "agent-sonarqube"
    Environment = "production"
    Project     = "currency-converter"
  }
}

# EKS Cluster in public subnets
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.0"

  cluster_name    = "currency-converter-cluster"
  cluster_version = "1.29"

  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.public.*.id

  eks_managed_node_groups = {
    default = {
      min_size       = 1
      max_size       = 2
      desired_size   = 1
      instance_types = ["t3.medium"]
      subnet_ids     = aws_subnet.public.*.id
      tags = {
        Environment = "production"
        Project     = "currency-converter"
      }
    }
  }

  cluster_endpoint_public_access = true

  tags = {
    Environment = "production"
    Project     = "currency-converter"
  }
}

# Outputs
output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  value = module.eks.cluster_security_group_id
}

output "jenkins_controller_public_ip" {
  value = aws_instance.jenkins_controller.public_ip
}

output "agent_sonarqube_public_ip" {
  value = aws_instance.agent_sonarqube.public_ip
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnets" {
  value = aws_subnet.public.*.id
}