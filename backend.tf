terraform {
  backend "s3" {
    bucket         = "vishnu-tf-state-1763122449"
    key            = "terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "vishnu-tf-state-1763122449-lock"
    encrypt        = true
  }
}
