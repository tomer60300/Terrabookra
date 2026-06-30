output "deployment_id" {
  description = "Aria deployment id."
  value       = vra_deployment.runner.id
}

output "deployment_name" {
  description = "Aria deployment name."
  value       = vra_deployment.runner.name
}

output "deployment_status" {
  description = "Aria deployment lifecycle status."
  value       = vra_deployment.runner.status
}

output "catalog_item_id" {
  description = "Resolved catalog item id used for the request."
  value       = data.vra_catalog_item.runner.id
}

output "project_id" {
  description = "Resolved Aria project id used for the request."
  value       = data.vra_project.this.id
}
