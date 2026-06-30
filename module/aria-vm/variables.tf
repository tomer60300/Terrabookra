variable "project_name" {
  type        = string
  description = "Existing Aria project name that is entitled to request the runner catalog item."

  validation {
    condition     = length(trimspace(var.project_name)) > 0
    error_message = "The project_name value must be non-empty."
  }
}

variable "catalog_item_name" {
  type        = string
  description = "Existing Service Broker catalog item name for Windows GitLab runners."

  validation {
    condition     = length(trimspace(var.catalog_item_name)) > 0
    error_message = "The catalog_item_name value must be non-empty."
  }
}

variable "catalog_item_version" {
  type        = string
  description = "Explicit catalog item version to request. Do not rely on latest."

  validation {
    condition     = length(trimspace(var.catalog_item_version)) > 0
    error_message = "The catalog_item_version value must be non-empty."
  }
}

variable "deployment_name" {
  type        = string
  description = "Stable, meaningful Aria deployment name."

  validation {
    condition     = length(trimspace(var.deployment_name)) > 0
    error_message = "The deployment_name value must be non-empty."
  }
}

variable "deployment_reason" {
  type        = string
  description = "Reason recorded on the Aria deployment request."
  default     = "Terraform-managed GitLab Windows runner deployment"
}

variable "vm_inputs" {
  type        = map(string)
  description = "Catalog request inputs. Every value must be a quoted string; the vra provider converts strings using the catalog schema."

  validation {
    condition     = length(var.vm_inputs) > 0
    error_message = "The vm_inputs map must not be empty."
  }
}
