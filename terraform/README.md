# `terraform/`

Terraform root module for Aria catalog deployment.

Terraform does not talk to vCenter directly. It uses `vmware/vra` to request an
existing Service Broker catalog item.

## Runtime

- Terraform `1.0.5`
- provider `vmware/vra` `0.17.2`
- provider mirror configured by `terraform.rc`
- refresh token supplied only as `TF_VAR_vra_refresh_token`

## Files

| File | Purpose |
| --- | --- |
| `main.tf` | Configures the `vra` provider and calls `module/aria-vm`. |
| `variables.tf` | Root input variables and validation. |
| `outputs.tf` | Deployment outputs. |
| `versions.tf` | Terraform and provider version pins. |
| `.terraform.lock.hcl` | Provider lock file. |
| `terraform.rc` | Offline provider mirror config. |
| `backend.tf.example` | Terraform 1.0.5-compatible S3 backend example. |
| `example.tfvars` | Public placeholder tfvars. Do not store secrets here. |

## Typical internal commands

```powershell
$env:TF_CLI_CONFIG_FILE = "$PWD\terraform\terraform.rc"
$env:TF_VAR_vra_refresh_token = '<masked secret>'

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-AriaTerraformPreflight.ps1
dist\bin\terraform.exe -chdir=terraform init
dist\bin\terraform.exe -chdir=terraform validate
dist\bin\terraform.exe -chdir=terraform plan -out=tfplan
dist\bin\terraform.exe -chdir=terraform apply -auto-approve tfplan
```

`vm_inputs` must remain `map(string)` because the provider and catalog schema own
the final type conversion.
