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
 
# Free-tier Ubuntu 22.04 AMI
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
 
# Security group with port 80 added
resource "aws_security_group" "strapi_sg" {
  name        = "strapi-sg"
  description = "Allow Strapi, Nginx, and SSH"
  vpc_id      = data.aws_vpc.default.id
 
  # Strapi direct port (1337)
  ingress {
    from_port   = var.strapi_port
    to_port     = var.strapi_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
 
  # Nginx HTTP port (80)
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
 
  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }
 
  # Outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
 
# USER DATA — Install docker + docker-compose.yml + run services
locals {
  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y
              apt-get install -y apt-transport-https ca-certificates curl software-properties-common
 
              # Install Docker
              curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
              add-apt-repository \
                "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
                $(lsb_release -cs) \
                stable"
              apt-get update -y
              apt-get install -y docker-ce docker-compose-plugin
 
              systemctl enable docker
              systemctl start docker
 
              # Create app folder
              mkdir -p /srv/strapi
              cd /srv/strapi
 
              # Create docker-compose.yml
              cat << 'EOC' > docker-compose.yml
              version: "3.8"
 
              services:
                postgres:
                  image: postgres:15
                  container_name: strapi-postgres
                  restart: unless-stopped
                  environment:
                    POSTGRES_DB: strapi
                    POSTGRES_USER: strapi
                    POSTGRES_PASSWORD: strapi123
                  volumes:
                    - postgres_data:/var/lib/postgresql/data
 
                strapi:
                  image: dityakp/strapi-app:latest
                  container_name: strapi-app
                  restart: unless-stopped
                  depends_on:
                    - postgres
                  ports:
                    - "1337:1337"
                  environment:
                    DATABASE_CLIENT: postgres
                    DATABASE_HOST: strapi-postgres
                    DATABASE_PORT: 5432
                    DATABASE_NAME: strapi
                    DATABASE_USERNAME: strapi
                    DATABASE_PASSWORD: strapi123
                    NODE_ENV: production
 
                nginx:
                  image: nginx:latest
                  container_name: strapi-nginx
                  restart: unless-stopped
                  ports:
                    - "80:80"
                  depends_on:
                    - strapi
                  volumes:
                    - ./nginx/default.conf:/etc/nginx/conf.d/default.conf
 
              volumes:
                postgres_data:
              EOC
 
              # Create nginx config
              mkdir -p nginx
              cat << 'EOC' > nginx/default.conf
              server {
                listen 80;
 
                location / {
                  proxy_pass http://strapi-app:1337;
                  proxy_set_header Host \$host;
                  proxy_set_header X-Real-IP \$remote_addr;
                  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto \$scheme;
                }
              }
              EOC
 
              # Start docker compose
              docker compose up -d
              EOF
}
 
resource "aws_instance" "strapi" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.strapi_sg.id]
  key_name               = var.key_name
  associate_public_ip_address = true
 
  user_data = local.user_data
 
  tags = {
    Name = "strapi-ubuntu-ec2"
  }
}
