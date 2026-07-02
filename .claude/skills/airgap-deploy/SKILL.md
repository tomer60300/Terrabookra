---
name: airgap-deploy
description: Operator playbook for importing Terrabookra into the internal air-gapped network, building the Packer golden image, and deploying runners through VMware Aria with Terraform.
---

# Air-gap deploy

Use this inside the internal network. There is no internet access. All binaries,
provider mirrors, Packer plugins, and container images must already exist in the
approved internal locations.

## Non-negotiables

- No public downloads.
- Terraform deploys through Aria Service Broker; it does not talk to vCenter.
- Packer may talk to vCenter for base/golden image builds.
- Terraform is `1.0.5`.
- Provider is `vmware/vra` `0.17.2` from `dist/providers`.
- PowerShell in guests is Windows PowerShell 5.1.
- SSH is the remote control plane.
- Secrets are injected through environment, CI masked variables, or guestinfo.
- Public aliases remain in source and resolve through internal DNS/hosts or
  `REAL_*` overrides.

## Step 0: Import transfer

```powershell
.\transfer\Import-Transfer.ps1 -InDir <usb>\<transfer-id> -Branch terraform
git lfs checkout
.\validation\Test-BuildInputs.ps1 -SkipRegistry
```

Fix missing or unsmudged LFS files before building.

## Step 1: Stage internal-only runtime

Required:

- `dist\bin\terraform.exe`
- offline `vmware/vra` provider mirror under `dist\providers`
- Packer executable/plugin mirror according to the internal build standard
- populated `binaries/` and `tools/` LFS artifacts
- gitignored Packer `*.auto.pkrvars.hcl`
- gitignored Terraform `*.auto.tfvars`

## Step 2: Build images

```powershell
packer init packer\base
packer validate -var-file packer\base\internal.auto.pkrvars.hcl packer\base\base.pkr.hcl
packer build -var-file packer\base\internal.auto.pkrvars.hcl packer\base\base.pkr.hcl

packer init packer\golden
packer validate -var-file packer\golden\internal.auto.pkrvars.hcl packer\golden\golden.pkr.hcl
packer build -var-file packer\golden\internal.auto.pkrvars.hcl packer\golden\golden.pkr.hcl
```

The golden build runs Phase 1, restart, Phase 2, restart, Phase 3, and the
build-gate. It produces a generic unregistered template.

## Step 3: Deploy through Terraform/Aria

```powershell
$env:TF_CLI_CONFIG_FILE = (Resolve-Path .\terraform\terraform.rc).Path
$env:TF_VAR_vra_refresh_token = '<masked process or CI secret>'

.\scripts\Test-AriaTerraformPreflight.ps1
.\dist\bin\terraform.exe -chdir=terraform init
.\dist\bin\terraform.exe -chdir=terraform validate
.\dist\bin\terraform.exe -chdir=terraform plan -out=tfplan
.\dist\bin\terraform.exe -chdir=terraform apply -auto-approve tfplan
```

## Aria catalog must provide

- correct golden template.
- VM hardware and network placement.
- raw/fixed data disk.
- VMware Tools.
- guestinfo or equivalent env injection for `runner_token`.
- optional `runner_hostname`, `registry_user`, `registry_pass`.

## Done means

- first boot creates `.firstboot_complete`.
- `gitlab-runner verify` is alive.
- a representative GitLab job runs on the new runner.
- fleet health reports the host healthy.
