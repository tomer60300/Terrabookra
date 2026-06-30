# Example tfvars for the Aria catalog-deployment path.
# Copy to a gitignored *.auto.tfvars on the internal leg and fill real names.
#
# DO NOT add vra_refresh_token here. Pass it only through:
#   $env:TF_VAR_vra_refresh_token = '<masked process env token>'

vra_url      = "https://be1.kayhut.com"
vra_insecure = true

project_name         = "Runners-Infra"
catalog_item_name    = "Windows Server 2019 GitLab Runner"
catalog_item_version = "1"
deployment_name      = "gitlab-runner-ws2019-01"
deployment_reason    = "Provision WS2019 GitLab runner through Service Broker catalog"

# Values are strings on purpose. The vmware/vra provider reads the catalog item
# schema and converts these strings to the schema-native types during request.
# Replace the keys below with the real Aria catalog item input names.
vm_inputs = {
  hostname          = "gitlab-runner-ws2019-01"
  os_version        = "windows-server-2019"
  runner_executor   = "docker-windows"
  container_os      = "ltsc2019"
  process_isolation = "true"
  cpu_count         = "24"
  memory_mb         = "65536"
  data_disk_gb      = "2048"
}
