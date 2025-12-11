terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.3.0"
}

provider "aws" {
  region = var.aws_region
}

# -------------------------
# Ubuntu 22.04 AMI
# -------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# -------------------------
# EC2 Security Group (Shantanu)
# -------------------------
resource "aws_security_group" "strapi_sg" {
  name        = "strapi-sg-shantanu"
  description = "Allow Strapi and SSH"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = var.strapi_port
    to_port     = var.strapi_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -------------------------
# RDS Security Group (Shantanu)
# -------------------------
resource "aws_security_group" "strapi_rds_sg" {
  name        = "strapi-rds-sg-shantanu"
  description = "Allow EC2 to access RDS"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -------------------------
# Allow EC2 → RDS
# -------------------------
resource "aws_security_group_rule" "allow_ec2_to_rds" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.strapi_rds_sg.id
  source_security_group_id = aws_security_group.strapi_sg.id
}

# -------------------------
# RDS Subnet Group (Shantanu)
# -------------------------
resource "aws_db_subnet_group" "strapi_db_subnet_group" {
  name       = "strapi-db-subnet-group-shantanu"
  subnet_ids = data.aws_subnets.default_subnets.ids
}

# -------------------------
# RDS PostgreSQL Instance (Shantanu)
# -------------------------
resource "aws_db_instance" "strapi_rds" {
  identifier              = "strapi-db-shantanu"
  allocated_storage       = 20
  engine                  = "postgres"
  instance_class          = "db.t3.micro"
  username                = "strapi"
  password                = "strapi123"
  db_name                 = "strapi_db"
  skip_final_snapshot     = true
  publicly_accessible     = false
  vpc_security_group_ids  = [aws_security_group.strapi_rds_sg.id]
  db_subnet_group_name    = aws_db_subnet_group.strapi_db_subnet_group.name
}

# -------------------------
# USER DATA — Install Docker + Run Strapi
# -------------------------
locals {
  user_data = <<-EOF
              #!/bin/bash

              apt-get update -y
              apt-get install -y docker.io

              systemctl start docker
              systemctl enable docker

              usermod -aG docker ubuntu

              # Pull Strapi image
              docker pull ${var.docker_image}

              # Wait for RDS to be ready
              sleep 90

              # Run Strapi container with RDS SSL settings
              docker run -d -p 1337:1337 \
                --name strapi \
                -e DATABASE_CLIENT=postgres \
                -e DATABASE_HOST=${aws_db_instance.strapi_rds.address} \
                -e DATABASE_PORT=5432 \
                -e DATABASE_NAME=strapi_db \
                -e DATABASE_USERNAME=strapi \
                -e DATABASE_PASSWORD=strapi123 \
                -e DATABASE_SSL=true \
                -e DATABASE_SSL__REJECT_UNAUTHORIZED=false \
                -e HOST=0.0.0.0 \
                -e PORT=1337 \
                ${var.docker_image}
              EOF
}

# -------------------------
# EC2 INSTANCE (Shantanu)
# -------------------------
resource "aws_instance" "strapi" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  vpc_security_group_ids      = [aws_security_group.strapi_sg.id]
  key_name                    = var.key_name
  associate_public_ip_address = true

  user_data = local.user_data

  tags = {
    Name = "strapi-ubuntu-ec2-shantanu"
  }
}
