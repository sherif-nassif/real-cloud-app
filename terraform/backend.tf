terraform {
  backend "gcs" {
    bucket = "tfstate-project-d318db8d"# you need to create the bucket first
    prefix = "terraform/state"
  }
}


