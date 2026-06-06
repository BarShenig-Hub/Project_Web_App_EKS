terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ─────────────────── Variables ───────────────────

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "couples_table_name" {
  description = "Name of the DynamoDB couples table"
  type        = string
  default     = "RSVP_Couples"
}

variable "rsvp_table_name" {
  description = "Name of the DynamoDB RSVP responses table"
  type        = string
  default     = "RSVP_Responses"
}

variable "docker_image" {
  description = "Docker image for the RSVP web application"
  type        = string
  default     = "shirbuchbut/web-app-rsvp:admin-01"
}

# ─────────────────── VPC ───────────────────

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "myRSVP"
  cidr = "10.0.0.0/16"

  azs            = ["${var.aws_region}a", "${var.aws_region}b"]
  public_subnets = ["10.0.1.0/24", "10.0.2.0/24"]

  manage_default_security_group = true

  default_security_group_ingress = [
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "Allow HTTP"
      cidr_blocks = "0.0.0.0/0"
    },
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      description = "Allow SSH"
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  default_security_group_egress = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  tags = {
    Owner       = "RSVP"
    Environment = "dev"
  }
}

# ─────────────────── DynamoDB Tables ───────────────────

resource "aws_dynamodb_table" "couples_table" {
  name         = var.couples_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "couple_id"

  attribute {
    name = "couple_id"
    type = "S"
  }

  tags = {
    Description = "Stores RSVP couples and event details"
  }
}

resource "aws_dynamodb_table" "rsvp_table" {
  name         = var.rsvp_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "phone"

  attribute {
    name = "phone"
    type = "S"
  }

  tags = {
    Description = "Stores RSVP guest responses"
  }
}

# ─────────────────── IAM Role for EC2 ───────────────────

resource "aws_iam_role" "ec2_rsvp_role" {
  name = "rsvp_ec2_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "RSVP EC2 IAM Role"
  }
}

resource "aws_iam_role_policy" "ec2_dynamodb_policy" {
  name = "rsvp_ec2_dynamodb_policy"
  role = aws_iam_role.ec2_rsvp_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = [
          aws_dynamodb_table.couples_table.arn,
          aws_dynamodb_table.rsvp_table.arn
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_rsvp_profile" {
  name = "rsvp_ec2_instance_profile"
  role = aws_iam_role.ec2_rsvp_role.name
}

# ─────────────────── EC2 Instance ───────────────────

resource "aws_instance" "rsvp_web" {
  ami                         = "ami-0c7217cdde317cfec"
  instance_type               = "t2.micro"
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [module.vpc.default_security_group_id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2_rsvp_profile.name

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y docker.io
    systemctl start docker
    systemctl enable docker

    docker pull ${var.docker_image}

    docker rm -f rsvp-admin-app || true

    docker run -d \
      -p 80:5000 \
      -e COUPLES_TABLE=${var.couples_table_name} \
      -e RSVP_TABLE=${var.rsvp_table_name} \
      -e AWS_REGION=${var.aws_region} \
      --restart always \
      --name rsvp-admin-app \
      ${var.docker_image}
  EOF

  tags = {
    Name = "RSVP-Admin-Web-Server"
  }

  depends_on = [
    aws_iam_instance_profile.ec2_rsvp_profile,
    aws_dynamodb_table.couples_table,
    aws_dynamodb_table.rsvp_table
  ]
}

# ─────────────────── Elastic IP ───────────────────

resource "aws_eip" "rsvp_eip" {
  domain = "vpc"

  tags = {
    Name = "RSVP-Elastic-IP"
  }
}

resource "aws_eip_association" "rsvp_eip_assoc" {
  instance_id   = aws_instance.rsvp_web.id
  allocation_id = aws_eip.rsvp_eip.id
}

# ─────────────────── Outputs ───────────────────

output "admin_address" {
  value       = "http://${aws_eip.rsvp_eip.public_ip}/admin"
  description = "Public URL of the RSVP Admin page"
}

output "website_base_address" {
  value       = "http://${aws_eip.rsvp_eip.public_ip}"
  description = "Base URL of the RSVP application"
}

output "elastic_ip" {
  value       = aws_eip.rsvp_eip.public_ip
  description = "Static Elastic IP attached to the EC2 instance"
}

output "couples_table_name" {
  value       = aws_dynamodb_table.couples_table.name
  description = "Name of the couples DynamoDB table"
}

output "rsvp_table_name" {
  value       = aws_dynamodb_table.rsvp_table.name
  description = "Name of the RSVP responses DynamoDB table"
}
