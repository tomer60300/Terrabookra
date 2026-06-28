output "runner_names" {
  description = "Deployed runner VM names."
  value       = [for r in vsphere_virtual_machine.runner : r.name]
}

output "runner_ips" {
  description = "Default IPv4 of each runner (populated after VMware Tools reports)."
  value       = { for k, r in vsphere_virtual_machine.runner : k => r.default_ip_address }
}

output "runner_uuids" {
  description = "vSphere UUIDs (handy for targeted taint/replace on token rotation)."
  value       = { for k, r in vsphere_virtual_machine.runner : k => r.uuid }
}
