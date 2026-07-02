# Build Runbook

Packer owns image construction. Terraform owns runner deployment. Do not use
Terraform provisioners to run the PowerShell phases.

## Build outputs

| Build | Input | Output |
| --- | --- | --- |
| Base | WS2019 ISO, VMware Tools ISO, offline OpenSSH zip | WS2019 template with OpenSSH |
| Golden | Base template, repo upload, LFS artifacts, registry access | Generic unregistered runner template |

## Base image

The base template is defined in `packer/base/base.pkr.hcl`.

It uses:

- Packer `vsphere-iso`.
- SSH communicator.
- unattended Windows install.
- offline OpenSSH setup from `tools/openssh/OpenSSH-Win64.zip`.

Example:

```powershell
packer init packer\base
packer validate -var-file packer\base\internal.auto.pkrvars.hcl packer\base\base.pkr.hcl
packer build -var-file packer\base\internal.auto.pkrvars.hcl packer\base\base.pkr.hcl
```

The temporary local Administrator password in the unattended install and the
Packer SSH password must match.

## Golden image

The golden template is defined in `packer/golden/golden.pkr.hcl`.

It uses:

- Packer `vsphere-clone`.
- SSH communicator.
- full repo upload to `C:\provision`.
- `provisioners/Invoke-Phase.ps1`.
- Packer `windows-restart` between phases.
- Phase 3 build-gate validation.

Example:

```powershell
packer init packer\golden
packer validate -var-file packer\golden\internal.auto.pkrvars.hcl packer\golden\golden.pkr.hcl
packer build -var-file packer\golden\internal.auto.pkrvars.hcl packer\golden\golden.pkr.hcl
```

## Phase responsibilities

| Phase | Responsibility |
| --- | --- |
| Phase 1 | Environment preflight, OS tuning, Windows features, cert import, OpenSSH, audit policy. |
| Phase 2 | Docker daemon config, `docker-users`, Docker binaries, service registration. |
| Phase 3 | Runner binary, token-less config skeleton, first-boot registration script, maintenance scripts, tools, observability, image pre-pulls, build-gate. |

## Build-gate behavior

Phase 3 fails the Packer build when:

- Docker is not ready.
- required binaries cannot be copied or validated.
- required pre-pull images cannot be pulled.
- scheduled task registration fails.
- observability installation fails.
- `Invoke-FinalValidation` marks the image invalid.

Tool and OpenCode failures are logged separately. The final build-gate still
checks the declared inventory so missing required tools are visible before the
image is shipped.

## Golden image identity

The golden image is intentionally unregistered:

- no runner token is baked into the image.
- no runner service is installed during the build.
- final `config.toml` is written at first boot.
- deploy validation runs only after first-boot registration.

This keeps the template reusable for many runner clones.
