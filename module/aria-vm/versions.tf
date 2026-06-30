terraform {
  required_version = "= 1.0.5"

  required_providers {
    vra = {
      source  = "vmware/vra"
      version = "= 0.17.2"
    }
  }
}
