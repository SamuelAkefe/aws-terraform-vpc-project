provider "aws" {
  region = "us-east-1"
}

# 1. VPC
resource "aws_vpc" "main_vpc" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"
  tags             = { Name = "main-vpc" }
}

# 2. Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id
  tags   = { Name = "main-igw" }
}

# 3. Public Subnet
resource "aws_subnet" "public_subnet" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
  #trivy:ignore:AVD-AWS-0164
  map_public_ip_on_launch = true
  tags                    = { Name = "public-subnet-1" }
}

# 4. Private Subnet
resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1a"
  tags              = { Name = "private-subnet-1" }
}

# 5. Route Table
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "public-route-table" }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# 6. S3 Bucket
#trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket" "app_bucket" {
  bucket_prefix = "flask-app-db-uploads-"
  force_destroy = true
  tags          = { Name = "Flask-Upload-Bucket" }
}

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
  bucket                  = aws_s3_bucket.app_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 7. IAM Role
resource "aws_iam_role" "ec2_s3_role" {
  name = "ec2_s3_access_role_v5"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "s3_upload_policy" {
  name = "s3_upload_policy"
  role = aws_iam_role.ec2_s3_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.app_bucket.arn,
        "${aws_s3_bucket.app_bucket.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2_s3_profile_v5"
  role = aws_iam_role.ec2_s3_role.name
}

# 8. Security Group
resource "aws_security_group" "public_sg" {
  name        = "flask_db_sg_v2"
  description = "Allow HTTP and SSH"
  vpc_id      = aws_vpc.main_vpc.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    #trivy:ignore:AVD-AWS-0107
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    #trivy:ignore:AVD-AWS-0104
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 9. EC2 Instance
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# ... (inside main.tf) ...

#trivy:ignore:AVD-AWS-0029
resource "aws_instance" "public_server" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.public_sg.id]
  key_name      = "my-terraform-key"

  # FORCE REPLACEMENT ON SCRIPT CHANGE (Add this line!)
  user_data_replace_on_change = true 

  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  user_data = <<-EOF
    #!/bin/bash
    # 1. Install System Dependencies
    yum update -y
    yum install -y python3-pip postgresql15-server postgresql-devel gcc python3-devel

    # 2. Init & Config Postgres
    postgresql-setup --initdb
    # FIX: Allow password auth
    sed -i 's/ident/md5/g' /var/lib/pgsql/data/pg_hba.conf
    systemctl enable postgresql
    systemctl start postgresql

    # 3. Create DB and User
    sudo -u postgres psql -c "CREATE USER flaskuser WITH PASSWORD 'flaskpass';"
    sudo -u postgres psql -c "CREATE DATABASE flaskdb OWNER flaskuser;"
    sudo -u postgres psql -d flaskdb -c "CREATE TABLE images (id SERIAL PRIMARY KEY, filename TEXT, bucket TEXT, s3_url TEXT, uploaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);"

    # 4. Install Python Libs (sudo for global install)
    sudo pip3 install flask boto3 psycopg2-binary

    # 5. Create Python App
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
        if request.method == 'POST':
            file = request.files['file']
            if file:
                try:
                    s3 = boto3.client('s3')
                    s3.upload_fileobj(file, BUCKET_NAME, file.filename)
                    s3_url = f"https://{aws_s3_bucket.app_bucket.id}.s3.amazonaws.com/{file.filename}"
                    
                    conn = get_db_connection()
                    cur = conn.cursor()
                    cur.execute("INSERT INTO images (filename, bucket, s3_url) VALUES (%s, %s, %s)", (file.filename, BUCKET_NAME, s3_url))
                    conn.commit()
                    cur.close()
                    conn.close()
                    status_msg = f"<p style='color:green'>Success! Uploaded <b>{file.filename}</b> and saved to DB.</p>"
                except Exception as e:
                    status_msg = f"<p style='color:red'>Error: {str(e)}</p>"

        try:
            conn = get_db_connection()
            cur = conn.cursor()
            cur.execute("SELECT id, filename, uploaded_at FROM images ORDER BY id DESC;")
            images = cur.fetchall()
            cur.close()
            conn.close()
        except:
            images = []

        rows = ""
        for img in images:
            rows += f"<tr><td>{img[0]}</td><td>{img[1]}</td><td>{img[2]}</td></tr>"

        return f"""
        <!doctype html>
        <style>
            body {{ font-family: sans-serif; text-align: center; padding: 20px; }}
            table {{ margin: 0 auto; border-collapse: collapse; width: 60%; }}
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

    # 6. Run App
    nohup python3 /home/ec2-user/app.py > /home/ec2-user/app.log 2>&1 &
  EOF

  tags = {
    Name = "flask-postgres-server"
  }
}

output "public_ip" {
  value = aws_instance.public_server.public_ip
}