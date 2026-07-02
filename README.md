# Terrabookra

Terrabookra builds and deploys Windows Server 2019 GitLab Runner machines for an
air-gapped network.

The current working branch is `terraform`. In this branch the deployment model is:

1. Code and Git LFS artifacts are transferred into the private network.
2. Packer builds a base WS2019 template with OpenSSH.
3. Packer builds a generic, unregistered golden runner template from that base.
4. Terraform requests an existing VMware Aria Service Broker catalog item.
5. The deployed clone registers itself on first boot from VMware guestinfo,
   environment variables, or `C:\GitLab-Runner\firstboot.json`.

The old Be1/MinIO self-fetch bootstrap path is retired here. `Bootstrap-GitLabRunner.ps1`
is a compatibility stub, not the active provisioner.

## Current contracts

- OS: Windows Server 2019 LTSC, build `17763`.
- Container runtime: Docker 25.x, `docker-windows`, process isolation.
- Runner: GitLab Runner `16.7.0`.
- Terraform: `1.0.5`.
- Terraform provider: `vmware/vra` `0.17.2` from the offline provider mirror.
- Packer vSphere plugin: `github.com/hashicorp/vsphere` `1.4.0`.
- Remote control plane: OpenSSH. WinRM is not part of the runtime path.
- Runtime images: GitLab Container Registry.
- Runtime/build binaries: repo files and Git LFS, not MinIO.

## Read first

- [Documentation index](docs/INDEX.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Configuration model](docs/CONFIGURATION.md)
- [Air-gap transfer](docs/AIRGAP-TRANSFER.md)
- [Build runbook](docs/BUILD.md)
- [Deployment runbook](docs/DEPLOYMENT.md)
- [Validation gates](docs/VALIDATION.md)
- [Operations](docs/OPERATIONS.md)
- [Open items](docs/OPEN-ITEMS.md)

## Repository map

| Path | Purpose |
| --- | --- |
| `.gitlab-ci.yml` | Internal GitLab CI for validate, plan, and manual deploy. |
| `.claude/verify-ps.ps1` | Windows PowerShell 5.1 parser and PSScriptAnalyzer gate. |
| `binaries/` | LFS-tracked runtime binaries such as Docker and GitLab Runner. |
| `ci/` | CI helper scripts. |
| `dist/` | Offline Terraform runtime and provider mirror, populated only internally. |
| `fleet/` | SSH-based fleet inspection and command helpers. |
| `lib/` | Shared configuration and helpers. |
| `module/aria-vm/` | Terraform module wrapping an Aria catalog deployment. |
| `packer/` | Base and golden-image Packer templates. |
| `phases/` | Build-time provisioning phases run by Packer. |
| `provisioners/` | Packer phase entrypoint and first-boot runner registration. |
| `scripts/` | Maintenance, observability, SSH, tooling, and diagnostics scripts. |
| `terraform/` | Terraform root module for Aria deployment. |
| `transfer/` | Git bundle and LFS CAS transfer tools for the air gap. |
| `validation/` | Build-input, build-gate, and deploy-gate validation. |

## Internal quick path

From the internal GitLab leg, after importing the transfer bundle and populating
the offline binary/provider content:

```powershell
git lfs checkout

powershell -NoProfile -ExecutionPolicy Bypass -File .claude\verify-ps.ps1 -Path .\phases\Phase1-SystemPrep.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-AriaTerraformPreflight.ps1 -SkipAriaApi

packer init packer\base
packer validate -var-file packer\base\internal.auto.pkrvars.hcl packer\base\base.pkr.hcl

packer init packer\golden
packer validate -var-file packer\golden\internal.auto.pkrvars.hcl packer\golden\golden.pkr.hcl

$env:TF_CLI_CONFIG_FILE = "$PWD\terraform\terraform.rc"
$env:TF_VAR_vra_refresh_token = '<masked CI or process secret>'
dist\bin\terraform.exe -chdir=terraform init
dist\bin\terraform.exe -chdir=terraform plan -out=tfplan
```

Use the GitLab CI pipeline for the normal path; the commands above are for
operator orientation and troubleshooting.

## Retired concepts

These names may still appear in old commit history, but they are not the active
runtime model on this branch:

- Be1 post-install phase dispatcher.
- MinIO/S3 script download during provisioning.
- Harbor image source.
- `exit 3010` reboot/resume contract.
- Runner registration during golden-image build.

The active source of truth is the code under `packer/`, `phases/`,
`provisioners/`, `lib/`, `terraform/`, `module/aria-vm/`, and `validation/`.
