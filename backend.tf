terraform {
  backend "s3" {
    # Replace this with your actual unique bucket name
    bucket = "terraform-state-locking-samuel40"

    # The path to the state file inside the bucket 
    key = "PROJECT2/backend.tf"

    # The region where the bucket exists
    region = "us-east-1"
  }
}