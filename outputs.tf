# 1. The Public IP address of your Server
output "server_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.public_server.public_ip
}

# 2. The URL to access your Website
output "website_url" {
  description = "URL to access the Flask Application"
  value       = "http://${aws_instance.public_server.public_ip}"
}

# 3. The Name of your S3 Bucket
output "s3_bucket_name" {
  description = "Name of the S3 bucket created for uploads"
  value       = aws_s3_bucket.app_bucket.id
}

# 4. Command to SSH into the server (Helper)
output "ssh_connection_command" {
  description = "Command to SSH into the instance"
  value       = "ssh -i ${var.key_name}.pem ec2-user@${aws_instance.public_server.public_ip}"
}