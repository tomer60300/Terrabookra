provider "vra" {
  url           = var.vra_url
  refresh_token = var.vra_refresh_token
  insecure      = var.vra_insecure
}

module "aria_vm" {
  source = "../module/aria-vm"

  project_name         = var.project_name
  catalog_item_name    = var.catalog_item_name
  catalog_item_version = var.catalog_item_version
  deployment_name      = var.deployment_name
  deployment_reason    = var.deployment_reason
  vm_inputs            = var.vm_inputs
}
