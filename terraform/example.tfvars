# Example tfvars for the Aria catalog-deployment path.
# Copy to a gitignored *.auto.tfvars on the internal leg and fill real names.
#
# DO NOT add vra_refresh_token here. Pass it only through:
#   $env:TF_VAR_vra_refresh_token = '<masked process env token>'

vra_url      = "https://aria.YOUR-DOMAIN.example" # the internal Aria/Service-Broker URL
vra_insecure = true                               # true only for an approved self-signed endpoint

project_name         = "YOUR_ARIA_PROJECT"                # existing Aria project name
catalog_item_name    = "YOUR_WINDOWS_RUNNER_CATALOG_ITEM" # existing Service Broker catalog item
catalog_item_version = "1"                                # explicit version -- do not rely on latest
deployment_name      = "gitlab-runner-ws2019-01"          # stable, meaningful deployment name
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
