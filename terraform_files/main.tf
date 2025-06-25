# Configuring the AWS provider
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

# EC2 instance for Jenkins controller (without Docker)
resource "aws_instance" "jenkins_controller" {
  ami                    = "ami-0c55b159cbfafe1f0" # Update for your region
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.jenkins_controller_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_instance_profile.name
  associate_public_ip_address = true
  key_name               = "my-key" # Replace with your EC2 key pair name

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y java-11-openjdk wget

              # Add swap space
              dd if=/dev/zero of=/swapfile bs=1M count=1024
              chmod 600 /swapfile
              mkswap /swapfile
              swapon /swapfile
              echo '/swapfile swap swap defaults 0 0' >> /etc/fstab

              # Install AWS CLI
              curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              unzip awscliv2.zip
              ./aws/install
              rm -rf awscliv2.zip aws

              # Install kubectl
              curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
              chmod +x kubectl
              mv kubectl /usr/local/bin/

              # Install Jenkins
              wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
              rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io.key
              yum install -y jenkins
              systemctl start jenkins
              systemctl enable jenkins
              EOF

  tags = {
    Name        = "jenkins-controller"
    Environment = "production"
    Project     = "currency-converter"
  }
}

# EC2 instance for Jenkins agent, SonarQube, Trivy, OWASP
resource "aws_instance" "agent_sonarqube" {
  ami                    = "ami-0c55b159cbfafe1f0" # Update for your region
  instance_type          = "t2.medium"
  subnet_id              = aws_subnet.public[1].id
  vpc_security_group_ids = [aws_security_group.agent_sonarqube_eks_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_instance_profile.name
  associate_public_ip_address = true
  key_name               = "my-key" # Replace with your EC2 key pair name

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y docker java-11-openjdk python3 git unzip

              # Install Docker
              systemctl start docker
              systemctl enable docker
              usermod -aG docker ec2-user

              # Add swap space (8 GiB for t2.medium)
              dd if=/dev/zero of=/swapfile bs=1M count=8192
              chmod 600 /swapfile
              mkswap /swapfile
              swapon /swapfile
              echo '/swapfile swap swap defaults 0 0' >> /etc/fstab

              # Install AWS CLI
              curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              unzip awscliv2.zip
              ./aws/install
              rm -rf awscliv2.zip aws

              # Install kubectl
              curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
              chmod +x kubectl
              mv kubectl /usr/local/bin/

              # Install SonarQube scanner
              curl -LO https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-5.0.1.3006-linux.zip
              unzip sonar-scanner-cli-5.0.1.3006-linux.zip
              mv sonar-scanner-5.0.1.3006 /opt/sonar-scanner
              echo 'export PATH=/opt/sonar-scanner/bin:$PATH' >> /home/ec2-user/.bashrc

              # Install Trivy
              rpm -ivh https://github.com/aquasecurity/trivy/releases/download/v0.45.1/trivy_0.45.1_Linux-64bit.rpm
              trivy --version

              # Install OWASP Dependency-Check
              curl -LO https://github.com/jeremylong/DependencyCheck/releases/download/v9.2.0/dependency-check-9.2.0-release.zip
              unzip dependency-check-9.2.0-release.zip
              mv dependency-check /opt/dependency-check
              echo 'export PATH=/opt/dependency-check/bin:$PATH' >> /home/ec2-user/.bashrc

              # Install SonarQube server
              docker run -d -p 9000:9000 --name sonarqube sonarqube:latest

              # Generate SSH key for Jenkins agent
              su - ec2-user -c "ssh-keygen -t rsa -b 4096 -C 'jenkins-agent@ci.com' -f /home/ec2-user/.ssh/id_rsa -N ''"
              chown ec2-user:ec2-user /home/ec2-user/.ssh/id_rsa*
              EOF

  tags = {
    Name        = "agent-sonarqube"
    Environment = "production"
    Project     = "currency-converter"
  }
}

# EKS Cluster in public subnets
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.15.3"

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