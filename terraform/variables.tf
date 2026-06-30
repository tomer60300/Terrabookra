variable "vra_url" {
  type        = string
  description = "VMware Aria Automation URL, for example https://aria.example.local."

  validation {
    condition     = can(regex("^https://", var.vra_url))
    error_message = "The vra_url value must be an https:// URL."
  }
}

variable "vra_refresh_token" {
  type        = string
  description = "Aria CSP refresh token. Pass only through TF_VAR_vra_refresh_token."
  sensitive   = true

  validation {
    condition     = length(trimspace(var.vra_refresh_token)) > 0
    error_message = "The vra_refresh_token value must be supplied through TF_VAR_vra_refresh_token."
  }
}

variable "vra_insecure" {
  type        = bool
  description = "Set true only for approved self-signed Aria endpoints."
  default     = false
}

variable "project_name" {
  type        = string
  description = "Existing Aria project name."
}

variable "catalog_item_name" {
  type        = string
  description = "Existing Service Broker catalog item name for Windows runners."
}

variable "catalog_item_version" {
  type        = string
  description = "Explicit Service Broker catalog item version."
}

variable "deployment_name" {
  type        = string
  description = "Stable Aria deployment name."
}

variable "deployment_reason" {
  type        = string
  description = "Reason recorded on the Aria deployment request."
  default     = "Terraform-managed GitLab Windows runner deployment"
}

variable "vm_inputs" {
  type        = map(string)
  description = "Catalog item inputs. Quote every value, including numbers and booleans."

  validation {
    condition     = length(var.vm_inputs) > 0
    error_message = "The vm_inputs map must not be empty."
  }
}
