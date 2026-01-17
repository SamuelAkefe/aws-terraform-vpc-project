provider "aws" {
  region = "us-east-1"
}

#!. Create the VPC
resource "aws_vpc" "main_vpc" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"

  tags = {
    Name = "main-vpc"
  }
}

# 2. Create an Internet Gateway (IGW)
# This acts as the door to the internet for public subnets.
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "main-igw"
  }
}

# 3. Create the Public Subnet 
resource "aws_subnet" "public_subnet" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"

  #trivy:ignore:AVD-AWS-0164
  map_public_ip_on_launch = true # Instances get public IPs by default 

  tags = {
    Name = "public-subnet-1"
  }
}

# 4. Create the Private Subnet 
resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "private-subnet-1"
  }
}

# 5. Create a Route Table for the Public Subnet 
# This directs internet-bound traffic to the IGW.
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

# 6. Associate the Public Subnet with the Public Route Table
resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id

}

#Elastic IP for NAT Gateway
resource "aws_eip" "nat_eip" {
  domain = "vpc"
}

# NAT Gateway (must live in the Public Subnet)
resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet.id

  tags = {
    Name = "main-nat-gw"
  }

  # To ensure proper ordering, it is recommended to add an explicit dependency
  depends_on = [aws_internet_gateway.igw]
}

# Private Route Table (Routes internet traffic through NAT Gateway)
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

# Associate Private Subnet with Private Route Table
resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private_rt.id
}

#10. Get the latest Amazon Linux 2023 AMI (OS) automatically
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}
# =================================
# S3 Bucket for Image Uploads

#==================================
resource "aws_s3_bucket" "app_bucket" {
  #trivy:ignore:AVD-AWS-0132
  bucket_prefix = "my-flask-app-uploads-" # Generates a unique name
  force_destroy = true                    # Allows deleting bucket even if it has files (for learning)

  tags = {
    Name = "Flask-Upload-Bucket"
  }
}

# Block Public Access (Security Best Practice)
#Enable Free Encryption (AES256)
resource "aws_s3_bucket_server_side_encryption_configuration" "app_bucket_crypto" {
  bucket = aws_s3_bucket.app_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}


resource "aws_s3_bucket_public_access_block" "app_bucket_acl" {
  bucket = aws_s3_bucket.app_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ==============================
# IAM Role (The "Passport" for EC2)
# 1. Create the Role
resource "aws_iam_role" "ec2_s3_role" {
  name = "ec2_s3_access_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

# 2. Grant Permission to Upload to S3 
resource "aws_iam_role_policy" "s3_upload_policy" {
  name = "s3_upload_policy"
  role = aws_iam_role.ec2_s3_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket"
      ]
      Resource = [
        aws_s3_bucket.app_bucket.arn,
        "${aws_s3_bucket.app_bucket.arn}/*"
      ]
    }]
  })
}

# 3. Create the Instance Profile (To attach role to EC2)
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2_s3_profile"
  role = aws_iam_role.ec2_s3_role.name
}

# 11. Create a Security Group (Firewall)
resource "aws_security_group" "public_sg" {
  name        = "public_ssh_sg"
  description = "Allow SSH and HTTP inbound traffic"
  vpc_id      = aws_vpc.main_vpc.id

  # Allow SSH from anywhere (In production, replace 0.0.0.0/0 with your own IP)
  ingress {
    description = "SSH from Internet"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    #trivy:ignore:AVD-AWS-0107
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow HTTP 
  ingress {
    description = "HTTP from Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic (so the server can download updates) 
  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    #trivy:ignore:AVD-AWS-0104
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "public-sg"
  }
}

# 12. Create the EC2 Instance in the Public Subnet
resource "aws_instance" "public_server" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public_subnet.id

  # Attach the Security Group we just created 
  vpc_security_group_ids = [aws_security_group.public_sg.id]

  # The name of the key pair you created in Step 1
  key_name = "my-terraform-key"

  # Attach the IAM Role
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  # Encrypt the Root Block Device
  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  # Enforce IMDSv2 (Secure Metadata)
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  # NEW: Python Flask App with S3 Upload
  # USER DATA SCRIPT
  user_data = <<EOF
#!/bin/bash 
# 1. Install Updates & Python
yum update -y
yum install -y python3-pip
pip3 install flask boto3

# 2. Create the Flask App
cat <<EOT >> /home/ec2-user/app.py
import os
import boto3
from flask import Flask, request, render_template_string

app = Flask(__name__)
BUCKET_NAME = '${aws_s3_bucket.app_bucket.id}' # Terraform injects the bucket name here

# HTML Template
HTML = """
<!doctype html>
<title>Upload new File</title>
<h1>Upload Image to S3</h1>
<form method=post enctype=multipart/form-data>
  <input type=file name=file>
  <input type=submit value=Upload>
</form>
"""

@app.route('/', methods=['GET', 'POST'])
def upload_file():
  if request.method == 'POST':
    file = request.files['file']
    if file:
      # Upload to S3 using IAM Role (No keys needed !)
      s3 = boto3.client('s3')
      s3.upload_fileobj(file, BUCKET_NAME, file.filename)
      return f"<h1>Success! Uploaded {file.filename} to S3 bucket: {BUCKET_NAME}</h1>"
  return HTML

if __name__ == '__main__':
  app.run(host='0.0.0.0', port=80)
EOT

# 3. Run the App (as root, so it can bind to port 80)
nohup python3 /home/ec2-user/app.py > /home/ec2-user/app.log 2>&1 & 
EOF
  tags = {
    Name = "flask-uplosd-server"
  }
}

# 13. Output the Public IP
# This tells Terraform to print the server's IP address after it finishes 
output "public_ip" {
  value = aws_instance.public_server.public_ip
}