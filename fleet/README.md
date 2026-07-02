# `fleet/`

Operator scripts for querying or commanding deployed runners over OpenSSH.

| Script | Purpose |
| --- | --- |
| `Get-FleetHealth.ps1` | Collect health, disk, Docker, runner, task, and exporter status from runners. |
| `Invoke-FleetCommand.ps1` | Run a PowerShell command or script across runners in parallel. |

Examples:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File fleet\Get-FleetHealth.ps1 `
  -Runners runner01,runner02 `
  -PrivateKey $env:USERPROFILE\.ssh\id_ed25519

powershell -NoProfile -ExecutionPolicy Bypass -File fleet\Invoke-FleetCommand.ps1 `
  -Runners runner01,runner02 `
  -PrivateKey $env:USERPROFILE\.ssh\id_ed25519 `
  -Command "Get-Service docker,gitlab-runner"
```

`Invoke-FleetCommand.ps1` requires `-PrivateKey` or `-KerberosAuth`. Password
prompts cannot work inside its background jobs.
