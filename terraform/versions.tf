terraform {
  required_version = ">= 1.3.0"

  required_providers {
    vsphere = {
      source  = "hashicorp/vsphere"
      version = "~> 2.8"
    }
  }

  # Spike/dev: local backend (default). For prod, use a locking, encrypted,
  # access-controlled backend. On the air-gapped leg this is GitLab-managed
  # Terraform state (HTTP backend) or MinIO-as-S3 with SSE + tight ACLs.
  # Uncomment + fill on the internal leg:
  #
  # backend "http" {
  #   address        = "https://gitlab.kayhut.com/api/v4/projects/<id>/terraform/state/runners"
  #   lock_address   = "https://gitlab.kayhut.com/api/v4/projects/<id>/terraform/state/runners/lock"
  #   unlock_address = "https://gitlab.kayhut.com/api/v4/projects/<id>/terraform/state/runners/lock"
  #   lock_method    = "POST"
  #   unlock_method  = "DELETE"
  #   retry_wait_min = 5
  # }
}
