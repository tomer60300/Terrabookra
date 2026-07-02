# Claude/Codex Project Notes

This repository is the Terrabookra `terraform` branch. Treat source code as the
truth and keep docs aligned to it.

## Active model

- Packer builds images.
- Terraform deploys through VMware Aria Service Broker.
- First boot registers the runner.
- Git LFS carries binaries into the internal leg.
- Runtime images come from GitLab Container Registry.
- OpenSSH is the remote control plane.

## Retired model

Do not reintroduce:

- Be1 phase orchestration.
- MinIO/S3 provisioning downloads.
- Harbor as the image source.
- `exit 3010` reboot control.
- runner registration during golden-image build.
- WinRM as a required remote path.

## Key source files

| Area | Files |
| --- | --- |
| Config and helpers | `lib/Config.ps1`, `lib/Common.ps1` |
| Packer images | `packer/base/*`, `packer/golden/*` |
| Build phases | `phases/*`, `provisioners/Invoke-Phase.ps1` |
| First boot | `provisioners/Register-RunnerFirstBoot.ps1` |
| Terraform | `terraform/*`, `module/aria-vm/*` |
| Validation | `.claude/verify-ps.ps1`, `validation/*`, `scripts/Test-AriaTerraformPreflight.ps1` |
| Transfer | `transfer/*` |

## Branch constraints

- Target OS is Windows Server 2019 LTSC, build `17763`.
- Docker uses Windows process isolation.
- Terraform is pinned to `1.0.5`.
- Provider is `vmware/vra` `0.17.2`.
- All production PowerShell must parse on Windows PowerShell 5.1.
- Avoid non-ASCII in target-executed PowerShell.
- Do not hardcode real internal FQDNs or credentials.
- Keep aliases wrapped by `REAL_*` overrides.

## Validation expectations

Before shipping source changes, prefer:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "$bad=0; Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object { & .claude\verify-ps.ps1 -Path $_.FullName; if ($LASTEXITCODE -ne 0) { $bad++ } }; if ($bad) { exit 1 }"
powershell -NoProfile -ExecutionPolicy Bypass -File ci\Validate-NoAliases.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-AriaTerraformPreflight.ps1 -SkipAriaApi
```

Full validation requires the internal lab: Packer build, Aria deploy, first boot,
and real GitLab job execution.
