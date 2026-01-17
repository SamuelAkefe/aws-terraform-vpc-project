Project Report: AWS Infrastructure Provisioning with Terraform
Project Title: Multi-Tier VPC Architecture with Public/Private Subnets and Automated Web Server Deployment Date: January 16, 2026 Tooling: Terraform (Infrastructure as Code), AWS
1. Project Overview
The goal of this project was to provision a secure, scalable network infrastructure on AWS using Terraform. The architecture follows industry best practices by segregating resources into Public (internet-facing) and Private (internal) subnets.
Key Features
•	Custom VPC: A dedicated virtual network (10.0.0.0/16) to isolate resources.
•	Public Subnet: Hosts a Bastion/Web server accessible via HTTP and SSH.
•	Private Subnet: Hosts internal servers with no direct incoming internet access.
•	NAT Gateway: Allows private servers to download updates without being exposed to the internet.
•	Automated Deployment: Uses user_data to automatically install and start Nginx on boot.
2. Architecture Diagram
•	VPC: 10.0.0.0/16
o	Public Subnet (10.0.1.0/24): Connected to Internet Gateway.
	Contains: Nginx Web Server / Bastion Host.
	Security: Ports 80 (HTTP) and 22 (SSH) open.
o	Private Subnet (10.0.2.0/24): Connected to NAT Gateway.
	Contains: Private Application Node.
	Security: Port 22 (SSH) open only from Public Subnet.
3. The Source Code (main.tf)
Updated January 16, 2026
Below is the final, corrected Terraform configuration. It includes the Public Web Tier (Nginx) and the Private App Tier (Python/Flask), with all syntax fixes applied.
Terraform
provider "aws" {
  region = "us-east-1"
}

# ---------------------------------------------------------
# NETWORK SKELETON (VPC & SUBNETS)
# ---------------------------------------------------------

# 1. Create the VPC
resource "aws_vpc" "main_vpc" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"

  tags = {
    Name = "main-vpc"
  }
}

# 2. Create Internet Gateway (IGW)
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "main-igw"
  }
}

# 3. Create Public Subnet
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet-1"
  }
}

# 4. Create Private Subnet
resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "private-subnet-1"
  }
}

# ---------------------------------------------------------
# ROUTING & CONNECTIVITY
# ---------------------------------------------------------

# 5. Public Route Table
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "public-route-table"
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# 6. Elastic IP for NAT Gateway
resource "aws_eip" "nat_eip" {
  domain = "vpc"
}

# 7. NAT Gateway
resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet.id

  tags = {
    Name = "main-nat-gw"
  }

  depends_on = [aws_internet_gateway.igw]
}

# 8. Private Route Table
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }

  tags = {
    Name = "private-route-table"
  }
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private_rt.id
}

# ---------------------------------------------------------
# SECURITY & COMPUTE
# ---------------------------------------------------------

# 9. Get latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# 10. Public Security Group (Web Tier)
resource "aws_security_group" "public_sg" {
  name        = "public_ssh_http_sg"
  description = "Allow SSH and HTTP inbound traffic"
  vpc_id      = aws_vpc.main_vpc.id

  ingress {
    description = "SSH from Internet"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP from Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 11. Private Security Group (App Tier)
resource "aws_security_group" "private_sg" {
  name        = "private_app_sg"
  description = "Allow SSH and App traffic from Public Subnet"
  vpc_id      = aws_vpc.main_vpc.id

  # Allow SSH from Public SG
  ingress {
    description     = "SSH from Public SG"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.public_sg.id]
  }

  # Allow App Traffic (Port 5000) from Public SG
  ingress {
    description     = "App Traffic from Public SG"
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.public_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 12. Public Instance (Web Server - Nginx)
resource "aws_instance" "public_server" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.public_sg.id]
  key_name = "my-terraform-key" 

  # User Data: Installs Nginx (Note: No indentation to prevent syntax errors)
  user_data = <<EOF
#!/bin/bash
yum update -y
yum install -y nginx
systemctl start nginx
systemctl enable nginx
EOF

  tags = {
    Name = "public-ec2-instance"
  }
}

# 13. Private Instance (App Server - Python/Flask)
resource "aws_instance" "private_server" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.private_subnet.id
  vpc_security_group_ids = [aws_security_group.private_sg.id]
  key_name      = "my-terraform-key" 

  # User Data: Installs Python/Flask API
  user_data = <<EOF
#!/bin/bash
yum update -y
yum install -y python3-pip
pip3 install flask
cat <<EOT >> /home/ec2-user/app.py
from flask import Flask
app = Flask(__name__)
@app.route('/')
def hello():
    return "Hello from the Private App Tier!"
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOT
nohup python3 /home/ec2-user/app.py &
EOF

  tags = {
    Name = "private-app-tier"
  }
}

# 14. Outputs
output "public_ip" {
  value = aws_instance.public_server.public_ip
}

output "private_ip" {
  value = aws_instance.private_server.private_ip
}
4. Troubleshooting & Lessons Learned
During the implementation, we encountered and resolved several key issues:
1.	Region Trap: Initially, the Terraform apply failed because the Key Pair was created in a different region than the infrastructure.
o	Fix: Recreated the Key Pair in us-east-1.
2.	User Data Syntax: The Nginx installation script initially failed silently.
o	Cause: Indentation (whitespace) before #!/bin/bash caused the server to treat the script as a text file.
o	Fix: Used <<EOF and removed all indentation to ensure the Shebang line was flush left.
3.	Connection Refused: curl returned "Connection refused" on Port 80.
o	Diagnosis: This confirmed the server was reachable (Firewall OK), but the service was not running.
o	Fix: Used terraform apply -replace to force a fresh instance creation with the corrected script.
5. Cleanup
To prevent ongoing charges for the NAT Gateway and EC2 instances, the infrastructure is destroyed when not in use:
Bash
terraform destroy


6. CI/CD Pipeline Automation (backend.tf & GitHub Actions)
Updated January 17, 2026

To transition from manual local deployment to automated cloud deployment, we implemented a CI/CD pipeline using GitHub Actions and AWS S3 for remote state management.

6.1 Remote State Configuration (backend.tf)
We moved the terraform.tfstate file from the local laptop to an S3 bucket. This ensures the GitHub Actions runner can access the current state of the infrastructure. We also added a DynamoDB table to prevent concurrent writes (State Locking).

File: backend.tf

Terraform

terraform {
  backend "s3" {
    # Replace with your actual S3 bucket name
    bucket         = "terraform-state-locking-YOUR-NAME"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    
    # Locking mechanism to prevent corrupting state during simultaneous runs
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
6.2 GitHub Actions Workflow (.github/workflows/terraform-deploy.yml)
This file defines the automation rules. Every time code is pushed to the main branch, GitHub spins up a secure container, validates the code, and applies changes to AWS.

File: .github/workflows/terraform-deploy.yml

YAML

name: "Terraform Infrastructure Deployment"

on:
  push:
    branches:
      - main
    pull_request:

permissions:
  contents: read

jobs:
  terraform:
    name: "Terraform"
    runs-on: ubuntu-latest
    
    steps:
      - name: Checkout
        uses: actions/checkout@v3

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v2
        with:
          terraform_version: 1.5.0

      - name: Terraform Init
        id: init
        run: terraform init
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          AWS_DEFAULT_REGION: us-east-1

      - name: Terraform Format
        id: fmt
        run: terraform fmt -check

      - name: Terraform Validate
        id: validate
        run: terraform validate

      - name: Terraform Plan
        id: plan
        if: github.event_name == 'pull_request'
        run: terraform plan -no-color -input=false
        continue-on-error: true
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          AWS_DEFAULT_REGION: us-east-1

      - name: Terraform Apply
        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
        run: terraform apply -auto-approve -input=false
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          AWS_DEFAULT_REGION: us-east-1



Understanding the YAML File (The "Robot Instructions")
Think of the YAML file as a recipe card you hand to a robot (GitHub Actions). Here is exactly what each block tells the robot to do:

1. The Trigger (on:)
YAML

on:
  push:
    branches:
      - main
  pull_request:
What it does: This tells the robot when to wake up.

Translation: "Wake up and run this script whenever someone pushes code to the main branch OR opens a Pull Request."

2. The Job Environment (jobs:)
YAML

jobs:
  terraform:
    name: "Terraform"
    runs-on: ubuntu-latest
What it does: This selects the computer to run on.

Translation: "Rent a fresh Linux server (Ubuntu) from GitHub's cloud for a few minutes to run these tasks."

3. Step 1: Get the Code (Checkout)
YAML

- name: Checkout
  uses: actions/checkout@v3
Translation: "Log into my repository and download all the files (main.tf, backend.tf, etc.) onto this Ubuntu server."

4. Step 2: Install Tools (Setup Terraform)
YAML

- name: Setup Terraform
  uses: hashicorp/setup-terraform@v2
Translation: "This is a plain Linux server; it doesn't have Terraform installed. Please download and install Terraform version 1.5.0 so we can use it."

5. Step 3: Login & Connect (Terraform Init)
YAML

- name: Terraform Init
  run: terraform init
  env:
    AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
    ...
Translation: "Run terraform init. I am giving you my secret AWS username and password (which I hid in GitHub Secrets) so you can talk to my S3 bucket and download the state file."

6. Step 4: Quality Control (Format & Validate)
YAML

- name: Terraform Format
  run: terraform fmt -check
Translation: "Check if the code looks messy (bad indentation). If it is ugly, stop right here and fail the build."

Translation (Validate): "Check for syntax errors (like typos or missing brackets)."

7. Step 5: The "Dry Run" (Terraform Plan)
YAML

if: github.event_name == 'pull_request'
run: terraform plan
The Logic: This step ONLY runs if you are doing a Pull Request (testing code).

Translation: "Pretend to run the code and tell me what would happen, but don't actually change anything in AWS yet."

8. Step 6: The "Big Red Button" (Terraform Apply)
YAML

if: github.ref == 'refs/heads/main' && github.event_name == 'push'
run: terraform apply -auto-approve
The Logic: This step ONLY runs if you pushed directly to the main branch.

Translation: "This is the real deal. Run terraform apply. Use -auto-approve because there is no human here to type 'yes'. Build the infrastructure now!"

