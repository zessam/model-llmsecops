terraform {
  # OpenTofu 1.8+ is REQUIRED, not merely recommended: backend.tf references
  # `var.state_bucket` inside the backend block, which relies on early variable
  # evaluation. Terraform rejects variables in backend blocks at any version, so
  # this stack is OpenTofu-only. Use `tofu`, not `terraform`.
  required_version = ">= 1.8.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
