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
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
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
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
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

  # USER DATA SCRIPT
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

# 13. Output the Public IP
# This tells Terraform to print the server's IP address after it finishes 
output "public_ip" {
  value = aws_instance.public_server.public_ip
}