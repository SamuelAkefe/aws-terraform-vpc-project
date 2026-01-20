variable "aws_region" {
  description = "The AWS region to deploy to"
  default     = "us-east-1"
}

variable "project_name" {
  description = "The name of the project (used for tags and naming)"
  default     = "flask-app"
}

variable "instance_type" {
  description = "The size of the server"
  default     = "t2.micro"
}

variable "key_name" {
  description = "The name of the SSH key pair"
  default     = "my-terraform-key"
}