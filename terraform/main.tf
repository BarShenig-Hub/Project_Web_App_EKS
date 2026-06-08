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
  default     = "barshenig/web-app-rsvp:05"
}

variable "ngrok_custom_domain" {
  description = "Your static free ngrok domain"
  type        = string
  default     = "sharper-unending-frill.ngrok-free.dev"
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

# ─────────────────── Cognito User Pool ───────────────────

resource "aws_cognito_user_pool" "rsvp_admins" {
  name = "rsvp-admin-pool"

  username_attributes = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_uppercase = true
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
  }

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  tags = {
    Name = "RSVP Admin User Pool"
  }
}

resource "aws_cognito_user_pool_domain" "rsvp_domain" {
  domain       = "rsvp-admin-${random_id.suffix.hex}"   # must be globally unique
  user_pool_id = aws_cognito_user_pool.rsvp_admins.id
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_cognito_user_pool_client" "rsvp_app_client" {
  name         = "rsvp-flask-client"
  user_pool_id = aws_cognito_user_pool.rsvp_admins.id

  generate_secret = true

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers = ["COGNITO"]

  callback_urls = ["https://${var.ngrok_custom_domain}/authorize"]
  logout_urls   = ["https://${var.ngrok_custom_domain}/login"]

  

  explicit_auth_flows = [
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]
}

# ─────────────────── Secret Manager ───────────────────

data "aws_secretsmanager_secret" "admin_credentials" {
  name = "rsvp/admin_credentials"
}

# ─────────────────── Outputs: Cognito ───────────────────

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.rsvp_admins.id
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.rsvp_app_client.id
}

output "cognito_domain" {
  value = "https://${aws_cognito_user_pool_domain.rsvp_domain.domain}.auth.${var.aws_region}.amazoncognito.com"
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
          "dynamodb:Scan",
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          aws_dynamodb_table.couples_table.arn,
          aws_dynamodb_table.rsvp_table.arn,
          data.aws_secretsmanager_secret.admin_credentials.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:AdminCreateUser",
          "cognito-idp:AdminSetUserPassword"
        ]
        Resource = [
          aws_cognito_user_pool.rsvp_admins.arn
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
    apt-get install -y docker.io python3 curl unzip
    systemctl start docker
    systemctl enable docker

    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install

    snap install ngrok
    snap connect ngrok:network-control

    sleep 5


    ADMIN_SECRET=$(aws secretsmanager get-secret-value \
      --region ${var.aws_region} \
      --secret-id rsvp/admin_credentials \
      --query SecretString \
      --output text)

    ADMIN_USER=$(echo "$ADMIN_SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
    ADMIN_PASS=$(echo "$ADMIN_SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")
    FLASK_SECRET=$(echo "$ADMIN_SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['flask_secret_key'])")
    COGNITO_SECRET=$(echo "$ADMIN_SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cognito_client_secret', ''))")
    NGROK_TOKEN=$(echo "$ADMIN_SECRET"   | python3 -c "import sys,json; print(json.load(sys.stdin)['ngrok_authtoken'])")

    /snap/bin/ngrok config add-authtoken "$NGROK_TOKEN"

    nohup /snap/bin/ngrok http 80 --url="${var.ngrok_custom_domain}" > /home/ubuntu/ngrok.log 2>&1 &

    aws cognito-idp admin-create-user \
      --region ${var.aws_region} \
      --user-pool-id ${aws_cognito_user_pool.rsvp_admins.id} \
      --username "$ADMIN_USER" \
      --user-attributes Name=email,Value="$ADMIN_USER" Name=email_verified,Value=true \
      --message-action SUPPRESS

    aws cognito-idp admin-set-user-password \
      --region ${var.aws_region} \
      --user-pool-id ${aws_cognito_user_pool.rsvp_admins.id} \
      --username "$ADMIN_USER" \
      --password "$ADMIN_PASS" \
      --permanent

    docker pull ${var.docker_image}
    docker rm -f rsvp-admin-app || true

    docker run -d \
      -p 80:5000 \
      -e COUPLES_TABLE=${var.couples_table_name} \
      -e RSVP_TABLE=${var.rsvp_table_name} \
      -e AWS_REGION=${var.aws_region} \
      -e COGNITO_USER_POOL_ID=${aws_cognito_user_pool.rsvp_admins.id} \
      -e COGNITO_CLIENT_ID=${aws_cognito_user_pool_client.rsvp_app_client.id} \
      -e ADMIN_USERNAME="$ADMIN_USER" \
      -e ADMIN_PASSWORD="$ADMIN_PASS" \
      -e COGNITO_CLIENT_SECRET="$COGNITO_SECRET" \
      -e COGNITO_DOMAIN=https://${aws_cognito_user_pool_domain.rsvp_domain.domain}.auth.${var.aws_region}.amazoncognito.com \
      -e APP_BASE_URL=https://${var.ngrok_custom_domain} \
      -e FLASK_SECRET_KEY="$FLASK_SECRET" \
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
  value = "https://${var.ngrok_custom_domain}/admin"
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
