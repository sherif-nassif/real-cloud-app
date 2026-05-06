terraform {
  backend "gcs" {
    bucket = "tfstate-project-d318db8d"
    prefix = "terraform/cloudops-test"
  }
}

