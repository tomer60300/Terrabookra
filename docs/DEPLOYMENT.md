# Deployment Runbook

Terraform deploys runner VMs through an existing VMware Aria Service Broker
catalog item. It does not talk to vCenter directly.

## Required internal layout

```text
dist\
  bin\terraform.exe
  providers\...
terraform\
  terraform.rc
  .terraform.lock.hcl
  <environment>.auto.tfvars
```

`terraform.rc` must point Terraform at the offline provider mirror.

## Required CI/process variables

| Variable | Purpose |
| --- | --- |
| `TF_CLI_CONFIG_FILE` | Path to `terraform\terraform.rc`. |
| `TF_VAR_vra_refresh_token` | Aria CSP refresh token. Must not be stored in tfvars. |
| `TF_VAR_vra_url` | Optional if not supplied by tfvars. |
| `TF_VAR_vra_insecure` | Optional. Use `true` only for approved self-signed Aria endpoints. |

Do not use `VRA_REFRESH_TOKEN`; the preflight rejects it.

## Terraform flow

```powershell
$env:TF_CLI_CONFIG_FILE = "$PWD\terraform\terraform.rc"
$env:TF_VAR_vra_refresh_token = '<masked process or CI secret>'

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-AriaTerraformPreflight.ps1
dist\bin\terraform.exe -chdir=terraform init
dist\bin\terraform.exe -chdir=terraform plan -out=tfplan
dist\bin\terraform.exe -chdir=terraform apply -auto-approve tfplan
```

In GitLab CI, `deploy` is manual and only runs on the `terraform` branch.

## Aria catalog contract

The repo can validate Terraform syntax and provider usage, but it cannot prove
the internals of the Aria catalog item. The catalog item must provide:

- the correct golden template.
- Windows Server 2019 compatible hardware.
- process-isolation compatible host settings.
- a raw or existing fixed NTFS data disk that can become `E:`.
- network access to GitLab and the GitLab Container Registry.
- VMware Tools with `vmtoolsd.exe`.
- guestinfo or equivalent environment injection for first-boot identity.

Required identity key:

- `runner_token`

Recommended identity keys:

- `runner_hostname`
- `registry_user`
- `registry_pass`

If the catalog does not map Terraform `vm_inputs` to those guest-side values, the
Terraform apply can succeed while the VM never becomes an operational runner.

## First boot success criteria

A runner clone is considered operational only after:

- first-boot registration succeeds.
- `gitlab-runner` service is installed and running.
- `gitlab-runner verify` reports the runner is alive.
- scheduled tasks are present.
- SSH and observability services are running.
- `.firstboot_complete` exists under `C:\GitLab-Runner`.

Failures leave `.firstboot_complete` unset and may create `.firstboot_failed`.
