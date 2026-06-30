output "deployment_id" {
  description = "Aria deployment id."
  value       = module.aria_vm.deployment_id
}

output "deployment_name" {
  description = "Aria deployment name."
  value       = module.aria_vm.deployment_name
}

output "deployment_status" {
  description = "Aria deployment lifecycle status."
  value       = module.aria_vm.deployment_status
}

output "catalog_item_id" {
  description = "Resolved catalog item id."
  value       = module.aria_vm.catalog_item_id
}

output "project_id" {
  description = "Resolved Aria project id."
  value       = module.aria_vm.project_id
}
