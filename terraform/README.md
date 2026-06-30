# `terraform/` - Aria catalog deployment for Windows runners

This Terraform root is the infra_tf-facing runner deploy surface. It does not
talk to vCenter. It requests an existing Aria Service Broker catalog item through
`vmware/vra` `0.17.2`, using Terraform `1.0.5` from `dist/bin/` and the provider
mirror in `dist/providers/`.

## Required runtime

- `dist/bin/terraform.exe` is exactly Terraform `1.0.5`.
- `dist/providers/` contains `vmware/vra` `0.17.2` for `windows_amd64`.
- `TF_CLI_CONFIG_FILE` points at `terraform/terraform.rc`.
- `.terraform.lock.hcl` pins `registry.terraform.io/vmware/vra` `0.17.2`.
- The Aria CSP refresh token is supplied only as `TF_VAR_vra_refresh_token`.

Do not put the refresh token in `terraform.tfvars`, `*.auto.tfvars`, command-line
arguments, logs, or state outputs.

## Aria objects that must already exist

- Aria project: `project_name`
- Service Broker catalog item: `catalog_item_name`
- Catalog item version: `catalog_item_version`
- Entitlement that lets the token principal request the catalog item
- Backing cloud template and its image/flavor/network mappings, if the catalog
  item uses those inputs
- Project quota and lease policy that allow the runner deployment

Terraform validates the project and catalog item with data sources. The preflight
script checks local runtime/mirror/token basics and probes Aria before apply.

## First run

```powershell
$env:TF_CLI_CONFIG_FILE = (Resolve-Path .\terraform\terraform.rc).ProviderPath
$env:TF_VAR_vra_refresh_token = '<masked process env token>'

.\scripts\Test-AriaTerraformPreflight.ps1
.\dist\bin\terraform.exe -chdir=terraform init -backend=false
.\dist\bin\terraform.exe -chdir=terraform validate
.\dist\bin\terraform.exe -chdir=terraform plan -refresh=false
.\dist\bin\terraform.exe -chdir=terraform plan
```

For production state, copy `backend.tf.example` to `backend.tf` on the internal
leg and fill the MinIO/GitLab state endpoint. Keep the backend syntax Terraform
1.0.5-compatible: `endpoint = "..."` and `force_path_style = true`; do not use
newer `endpoints {}` or `use_path_style` syntax.

## `vm_inputs`

`vm_inputs` is `map(string)` on purpose. Quote every value, including numbers and
booleans:

```hcl
vm_inputs = {
  hostname          = "gitlab-runner-ws2019-01"
  cpu_count         = "24"
  memory_mb         = "65536"
  process_isolation = "true"
}
```

Replace the example keys with the real input names from the Service Broker
catalog item schema. Wrong keys or wrong versions fail during the Aria request,
so verify them with the preflight/catalog owner before apply.
