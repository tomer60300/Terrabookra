# Dev-leg verification suite

Static + logic verification that runs on a **Linux host with PowerShell 7** (no Windows, no vSphere, no
air-gapped infra). It is the dev/internet-leg safety net; the Windows/lab smoke tests remain separate.

## What runs
- `logic-tests.ps1` — mock-executes the cross-platform PowerShell logic: `Config.ps1` env-alias
  resolution (+ Harbor/MinIO/Be1 retirement), `Common.ps1` artifact helpers (`Get-RepoPath`,
  `Copy-RepoFile`, `Install-LocalBinary`/`Install-LocalArchive`, `Test-PEBinary`), and the
  build-gate/deploy-gate split (`Invoke-FinalValidation` vs `Test-RunnerRegistered`). Windows-only cmdlets
  (`Get-Service`, `Get-ScheduledTask`, …) are stubbed; native exes are shimmed.
- `transfer-roundtrip.ps1` — a REAL `git` + `git-lfs` round-trip of `transfer/Export-Transfer.ps1` +
  `Import-Transfer.ps1` (bundle + LFS CAS + manifest SHA-verify + checkout + tamper-rejection). No mocks.

## Run
```bash
pwsh -NoProfile -File tests/dev-leg/run-all.ps1
```
Requires `pwsh` and (for the transfer test) `git` + `git-lfs`.

## Also part of dev-leg verification (run separately, not in this folder)
- `terraform fmt -check` + `init -backend=false` (filesystem mirror) + `validate` on `terraform/`.
- `packer fmt -check` + `packer validate` on `packer/base` and `packer/golden` (vsphere plugin).
- `[Parser]::ParseInput` on every `.ps1`; `xmllint --noout packer/base/autounattend.xml`.
- `ci/Validate-NoAliases.ps1` (exit 0 clean / 1 on a hardcoded-host violation).

## Caveats (do NOT read green here as production-ready)
- **pwsh 7 ≠ Windows PowerShell 5.1** — parser/cmdlet-behavior deltas exist. The 5.1 engine (`verify-ps`)
  is still authoritative.
- Windows cmdlet **behavior is mocked** — these prove our call shapes + control flow, not the real cmdlets.
- **Still lab-only / UNVERIFIED:** `Register-RunnerFirstBoot.ps1` end-to-end (hardcoded `C:\` paths),
  docker-windows containers, vSphere clone + guestinfo, reboot-resume under `windows-restart`, and a full
  `packer build` / `terraform apply` against real infrastructure.
