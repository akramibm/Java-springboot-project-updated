terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# -----------------------------------------------------------------------------
# VARIABLES
# -----------------------------------------------------------------------------
variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "db_username" {
  type    = string
  default = "admin"
}

variable "db_password" {
  type      = string
  sensitive = true
  default   = "SuperSecretPass123!"
}

# -----------------------------------------------------------------------------
# PROVIDER & DATA SOURCES
# -----------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# -----------------------------------------------------------------------------
# VPC & NETWORKING
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "three-tier-vpc"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "three-tier-igw"
  }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "three-tier-public-sn-${count.index + 1}"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "three-tier-private-sn-${count.index + 1}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "three-tier-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# S3 ARTIFACT BUCKET FOR DEPLOYMENTS
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "deploy_artifacts" {
  bucket_prefix = "three-tier-deploy-artifacts-"
  force_destroy = true

  tags = {
    Name = "three-tier-deploy-artifacts"
  }
}

# -----------------------------------------------------------------------------
# SECURITY GROUPS
# -----------------------------------------------------------------------------
resource "aws_security_group" "web_sg" {
  name        = "app-server-sg"
  description = "HTTP and internal services - Zero SSH Ports"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Nginx Frontend"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Spring Boot Application"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "app-server-sg"
  }
}

resource "aws_security_group" "rds_sg" {
  name        = "rds-mysql-sg"
  description = "MySQL access restricted to EC2 app instances"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MySQL from App Security Group"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "rds-mysql-sg"
  }
}

# -----------------------------------------------------------------------------
# RDS MYSQL (USES name_prefix TO PREVENT SUBNET GROUP COLLISIONS)
# -----------------------------------------------------------------------------
resource "aws_db_subnet_group" "rds_subnets" {
  name_prefix = "three-tier-db-sn-"
  subnet_ids  = aws_subnet.private[*].id

  tags = {
    Name = "three-tier-db-subnet-group"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "mysql" {
  allocated_storage      = 20
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  db_name                = "appdb"
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.rds_subnets.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  skip_final_snapshot    = true

  tags = {
    Name = "three-tier-rds-mysql"
  }
}

# -----------------------------------------------------------------------------
# IAM ROLE (USES name_prefix TO PREVENT 409 EntityAlreadyExists)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ec2_app_role" {
  name_prefix = "three-tier-ec2-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ssm_read" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess"
}

resource "aws_iam_role_policy" "s3_pull_artifacts" {
  name_prefix = "ec2-s3-pull-"
  role        = aws_iam_role.ec2_app_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Effect   = "Allow"
      Resource = [
        aws_s3_bucket.deploy_artifacts.arn,
        "${aws_s3_bucket.deploy_artifacts.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "app_profile" {
  name_prefix = "three-tier-app-"
  role        = aws_iam_role.ec2_app_role.name
}

# -----------------------------------------------------------------------------
# EC2 INSTANCE (MANAGED VIA AWS SYSTEMS MANAGER)
# -----------------------------------------------------------------------------
resource "aws_instance" "app_server" {
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = var.instance_type
  subnet_id            = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  iam_instance_profile = aws_iam_instance_profile.app_profile.name

  tags = {
    Name = "three-tier-app-server"
    Role = "three-tier-app"
  }

  user_data = <<-EOF
              #!/bin/bash
              set -e

              apt-get update -y
              apt-get install -y openjdk-17-jdk python3 python3-pip python3-venv nginx awscli jq
              snap install amazon-ssm-agent --classic || systemctl enable amazon-ssm-agent
              systemctl start amazon-ssm-agent

              mkdir -p /opt/backend /opt/frontend /opt/config
              chown -R ubuntu:ubuntu /opt/backend /opt/frontend /opt/config

              # Nginx Reverse Proxy
              cat << 'NGINX' > /etc/nginx/sites-available/default
              server {
                  listen 80 default_server;
                  listen [::]:80 default_server;

                  location / {
                      proxy_pass http://127.0.0.1:5000;
                      proxy_set_header Host \$host;
                      proxy_set_header X-Real-IP \$remote_addr;
                  }

                  location /api/ {
                      proxy_pass http://127.0.0.1:8080/;
                      proxy_set_header Host \$host;
                      proxy_set_header X-Real-IP \$remote_addr;
                  }
              }
              NGINX
              systemctl restart nginx

              # Backend Unit
              cat << 'SERVICE' > /etc/systemd/system/backend.service
              [Unit]
              Description=Spring Boot Zero-Touch Backend
              After=network.target

              [Service]
              User=ubuntu
              WorkingDirectory=/opt/backend
              ExecStartPre=/bin/bash -c 'aws ssm get-parameter --name "/app/db_url" --region ${var.aws_region} --query "Parameter.Value" --output text > /opt/config/db_url.env'
              ExecStart=/bin/bash -c 'export SPRING_DATASOURCE_URL=$(cat /opt/config/db_url.env); exec /usr/bin/java -Dspring.datasource.url=$SPRING_DATASOURCE_URL -Dspring.datasource.username=${var.db_username} -Dspring.datasource.password=${var.db_password} -jar /opt/backend/datastore-0.0.7.jar'
              SuccessExitStatus=143
              Restart=always
              RestartSec=10

              [Install]
              WantedBy=multi-user.target
              SERVICE

              # Frontend Unit
              cat << 'SERVICE' > /etc/systemd/system/frontend.service
              [Unit]
              Description=Python Frontend Service
              After=network.target

              [Service]
              User=ubuntu
              WorkingDirectory=/opt/frontend
              ExecStart=/opt/frontend/venv/bin/python app.py
              Restart=always
              RestartSec=5

              [Install]
              WantedBy=multi-user.target
              SERVICE

              systemctl daemon-reload
              systemctl enable backend.service
              systemctl enable frontend.service
              EOF
}

# -----------------------------------------------------------------------------
# SSM PARAMETERS (overwrite = true PREVENTS ParameterAlreadyExists)
# -----------------------------------------------------------------------------
resource "aws_ssm_parameter" "db_url" {
  name      = "/app/db_url"
  type      = "String"
  value     = "jdbc:mysql://${aws_db_instance.mysql.endpoint}/${aws_db_instance.mysql.db_name}?useSSL=false&allowPublicKeyRetrieval=true"
  overwrite = true
}

resource "aws_ssm_parameter" "artifact_bucket" {
  name      = "/app/artifact_bucket"
  type      = "String"
  value     = aws_s3_bucket.deploy_artifacts.bucket
  overwrite = true
}

# -----------------------------------------------------------------------------
# OUTPUTS
# -----------------------------------------------------------------------------
output "ec2_public_ip" {
  description = "Public IP of the application server"
  value       = aws_instance.app_server.public_ip
}

output "rds_endpoint" {
  description = "Connection endpoint for RDS MySQL"
  value       = aws_db_instance.mysql.endpoint
}

output "s3_bucket" {
  description = "Deployment artifact S3 bucket"
  value       = aws_s3_bucket.deploy_artifacts.bucket
}