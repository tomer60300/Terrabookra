# `scripts/`

Runtime and build support scripts copied into the golden image.

## Build and install helpers

| Script | Purpose |
| --- | --- |
| `Assert-Environment.ps1` | Fail-fast Phase 1 preflight. |
| `Enable-RemoteSSH.ps1` | Installs and configures OpenSSH server. |
| `Import-Certificates.ps1` | Stages repo certificates and imports trusted roots. |
| `Install-Tools.ps1` | Table-driven install from `Config.ToolPackages`. |
| `Install-OpenCode.ps1` | Installs WebView2/OpenCode and machine config. |
| `Install-Observability.ps1` | Installs windows_exporter and blackbox_exporter. |
| `Register-ScheduledTasks.ps1` | Registers maintenance scheduled tasks. |
| `Write-GoldenVersion.ps1` | Writes `C:\GitLab-Runner\.golden-version`. |

## Runtime maintenance

| Script | Purpose |
| --- | --- |
| `health-check.ps1` | Docker, runner, disk, and stale-container health summary. |
| `disk-monitor.ps1` | Disk pressure checks for C: and the data drive. |
| `docker-watchdog.ps1` | Restarts Docker and runner service if Docker is unresponsive. |
| `kill-stale-containers.ps1` | Kills long-running containers using `docker inspect StartedAt`. |
| `Test-NetworkConnectivity.ps1` | TCP probe logging for configured monitor hosts. |
| `Export-RdpAuditLog.ps1` | RDP audit log extraction. |
| `Export-RunnerLogs.ps1` | Diagnostic bundle collector. |
| `Write-JobLog.ps1` | Runner job start/end wrapper logging. |

## Terraform CI helper

`Test-AriaTerraformPreflight.ps1` validates the offline Terraform runtime,
provider mirror, token discipline, Terraform syntax constraints, and Aria API
reachability.
