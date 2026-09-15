# -----------------------------------------------------------------------------
# S3 BUCKET FOR DEPLOYMENT ARTIFACTS
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "deploy_artifacts" {
  bucket_prefix = "three-tier-deploy-artifacts-"
  force_destroy = true

  tags = {
    Name = "three-tier-deploy-artifacts"
  }
}

# -----------------------------------------------------------------------------
# IAM ROLE FOR EC2 (SSM AGENT + S3 READ ACCESS)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ec2_app_role" {
  name = "three-tier-ec2-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Allows EC2 to communicate with AWS Systems Manager
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Allows EC2 to read DB URL parameter
resource "aws_iam_role_policy_attachment" "ssm_read" {
  role       = aws_iam_role.ec2_app_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess"
}

# Allows EC2 to pull deployment artifacts from S3
resource "aws_iam_role_policy" "s3_pull_artifacts" {
  name = "ec2-s3-pull-artifacts"
  role = aws_iam_role.ec2_app_role.id

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
  name = "three-tier-app-instance-profile"
  role = aws_iam_role.ec2_app_role.name
}

# -----------------------------------------------------------------------------
# SECURITY GROUP (PORT 22 REMOVED - SECURE BY DEFAULT)
# -----------------------------------------------------------------------------
resource "aws_security_group" "web_sg" {
  name        = "app-server-sg"
  description = "HTTP and internal services - No SSH port open"
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

# -----------------------------------------------------------------------------
# EC2 INSTANCE (TAGGED FOR SSM RUN COMMAND TARGETING)
# -----------------------------------------------------------------------------
resource "aws_instance" "app_server" {
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = var.instance_type
  subnet_id            = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  iam_instance_profile = aws_iam_instance_profile.app_profile.name

  # Tag used by GitHub Actions SSM Run Command to target this instance
  tags = {
    Name = "three-tier-app-server"
    Role = "three-tier-app"
  }

  user_data = <<-EOF
              #!/bin/bash
              set -e

              # Dependencies (Ubuntu Jammy includes snapd and amazon-ssm-agent pre-installed)
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
# STORE ARTIFACT BUCKET IN SSM (READABLE BY GITHUB ACTIONS)
# -----------------------------------------------------------------------------
resource "aws_ssm_parameter" "artifact_bucket" {
  name  = "/app/artifact_bucket"
  type  = "String"
  value = aws_s3_bucket.deploy_artifacts.bucket
}