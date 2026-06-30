data "vra_project" "this" {
  name = var.project_name
}

data "vra_catalog_item" "runner" {
  name            = var.catalog_item_name
  project_id      = data.vra_project.this.id
  expand_versions = true
}

resource "vra_deployment" "runner" {
  name        = var.deployment_name
  description = "GitLab Windows runner deployment requested by Terraform"
  reason      = var.deployment_reason

  project_id           = data.vra_project.this.id
  catalog_item_id      = data.vra_catalog_item.runner.id
  catalog_item_version = var.catalog_item_version
  inputs               = var.vm_inputs

  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }
}
