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
#trivy:ignore:AVD-AWS-0132
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
  vpc_security_group_ids = [aws_security_group.public_sg.id]
  key_name      = "my-terraform-key"

  # Attach IAM Role
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  # Security (Trivy)
  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  # NEW USER DATA: Python Flask + PostgreSQL Setup
  user_data = <<EOF
#!/bin/bash
# 1. Install Python, Postgres Server, and Build Tools
yum update -y
yum install -y python3-pip postgresql15-server postgresql-devel gcc python3-devel

# 2. Initialize & Start PostgreSQL
postgresql-setup --initdb
systemctl enable postgresql
systemctl start postgresql

# 3. Configure Database (Create User, DB, and Table)
# Note: In production, never put passwords in plain text! Use AWS Secrets Manager.
sudo -u postgres psql -c "CREATE USER flaskuser WITH PASSWORD 'flaskpass';"
sudo -u postgres psql -c "CREATE DATABASE flaskdb OWNER flaskuser;"
sudo -u postgres psql -d flaskdb -c "CREATE TABLE images (id SERIAL PRIMARY KEY, filename TEXT, bucket TEXT, s3_url TEXT, uploaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);"

# 4. Install Python Libraries (Flask, Boto3, Psycopg2)
pip3 install flask boto3 psycopg2-binary

# 5. Create the Flask App
cat <<EOT >> /home/ec2-user/app.py
import boto3
import psycopg2
from flask import Flask, request

app = Flask(__name__)
BUCKET_NAME = '${aws_s3_bucket.app_bucket.id}'
DB_HOST = "localhost"
DB_NAME = "flaskdb"
DB_USER = "flaskuser"
DB_PASS = "flaskpass"

def get_db_connection():
    conn = psycopg2.connect(host=DB_HOST, database=DB_NAME, user=DB_USER, password=DB_PASS)
    return conn

@app.route('/', methods=['GET', 'POST'])
def index():
    status_msg = ""
    
    # Handle File Upload
    if request.method == 'POST':
        file = request.files['file']
        if file:
            # 1. Upload to S3
            s3 = boto3.client('s3')
            s3.upload_fileobj(file, BUCKET_NAME, file.filename)
            s3_url = f"https://{BUCKET_NAME}.s3.amazonaws.com/{file.filename}"
            
            # 2. Save Metadata to PostgreSQL
            conn = get_db_connection()
            cur = conn.cursor()
            cur.execute("INSERT INTO images (filename, bucket, s3_url) VALUES (%s, %s, %s)",
                        (file.filename, BUCKET_NAME, s3_url))
            conn.commit()
            cur.close()
            conn.close()
            status_msg = f"<p style='color:green'>Success! Uploaded <b>{file.filename}</b> and saved to DB.</p>"

    # Fetch History from DB to display
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("SELECT id, filename, uploaded_at FROM images ORDER BY id DESC;")
    images = cur.fetchall()
    cur.close()
    conn.close()

    # Generate HTML Table
    rows = ""
    for img in images:
        rows += f"<tr><td>{img[0]}</td><td>{img[1]}</td><td>{img[2]}</td></tr>"

    return f"""
    <!doctype html>
    <style>
        body {{ font-family: sans-serif; text-align: center; padding: 20px; }}
        table {{ margin: 0 auto; border-collapse: collapse; width: 50%; }}
        th, td {{ border: 1px solid #ddd; padding: 8px; }}
        th {{ background-color: #f2f2f2; }}
    </style>
    <h1>Cloud Image Uploader (S3 + Postgres)</h1>
    {{status_msg}}
    <form method="post" enctype="multipart/form-data">
        <input type="file" name="file" required>
        <input type="submit" value="Upload">
    </form>
    <br><hr><br>
    <h2>Database Records</h2>
    <table>
        <tr><th>ID</th><th>Filename</th><th>Time Uploaded</th></tr>
        {{rows}}
    </table>
    """

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80)
EOT

# 6. Run the App
nohup python3 /home/ec2-user/app.py > /home/ec2-user/app.log 2>&1 &
EOF

  tags = {
    Name = "flask-postgres-server"
  }
}

# 13. Output the Public IP
# This tells Terraform to print the server's IP address after it finishes 
output "public_ip" {
  value = aws_instance.public_server.public_ip
}