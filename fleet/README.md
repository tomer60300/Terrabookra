# Fleet Management Scripts

These scripts run from your **admin PC**, NOT on the runners.
They use WinRM PSRemoting (enabled by `scripts/Enable-RemotePowerShell.ps1`).

## Scripts

| Script | Purpose |
|---|---|
| `Get-FleetHealth.ps1` | Query all runners, display health dashboard table |
| `Invoke-FleetCommand.ps1` | Execute any command across all runners in parallel |

## Quick Start

```powershell
# Health dashboard
.\fleet\Get-FleetHealth.ps1 -Runners runner01,runner02,runner03

# Restart Docker everywhere
.\fleet\Invoke-FleetCommand.ps1 -Runners runner01,runner02 -Command 'Restart-Service docker -Force'

# Collect log bundles from all runners
.\fleet\Invoke-FleetCommand.ps1 -Runners runner01,runner02 -Command 'C:\GitLab-Runner\scripts\Export-RunnerLogs.ps1'

# Check golden image versions
.\fleet\Invoke-FleetCommand.ps1 -Runners runner01,runner02 -Command 'Get-Content C:\GitLab-Runner\.golden-version'
```

## Tips

- Store runner hostnames in a `runners.txt` file and use `(Get-Content .\runners.txt)` as the `-Runners` parameter.
- Use `-Credential (Get-Credential)` if your admin PC isn't domain-joined.
- Use `-ExportCsv fleet-status.csv` on Get-FleetHealth to save results.
