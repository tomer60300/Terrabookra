# Operations

This page covers the deployed runner after first boot.

## Health signals

| Signal | Location |
| --- | --- |
| First boot complete | `C:\GitLab-Runner\.firstboot_complete` |
| First boot failed | `C:\GitLab-Runner\.firstboot_failed` |
| Golden image metadata | `C:\GitLab-Runner\.golden-version` |
| Install/provisioning log | `C:\GitLab-Runner\logs\install.log` |
| Health log | `C:\GitLab-Runner\logs\health-check.log` |
| Disk monitor log | `C:\GitLab-Runner\logs\disk-monitor.log` |
| Docker watchdog log | `C:\GitLab-Runner\logs\docker-watchdog.log` |
| Stale container log | `C:\GitLab-Runner\logs\stale-containers.log` |
| Network probes | `C:\GitLab-Runner\logs\network\*.csv` |
| Job wrapper logs | `C:\GitLab-Runner\logs\jobs\*.log` |

## Scheduled tasks

`scripts/Register-ScheduledTasks.ps1` registers the maintenance tasks:

- `Docker-Image-Prune`
- `Docker-Container-Cleanup`
- `Docker-Stale-Container-Kill`
- `Docker-Volume-Prune`
- `Docker-BuildCache-Prune`
- `Runner-Workspace-Cleanup`
- `Disk-Space-Monitor`
- `Docker-Daemon-Watchdog`
- `Runner-Service-Watchdog`
- `Log-Rotation`
- `Network-Connectivity-Monitor`
- `RDP-Audit-Logger`
- `Health-Check`

The deploy-gate checks that all required tasks exist.

## Fleet operations

Use the scripts under `fleet/` from an admin machine with OpenSSH client access:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File fleet\Get-FleetHealth.ps1 `
  -Runners runner01,runner02 `
  -PrivateKey $env:USERPROFILE\.ssh\id_ed25519

powershell -NoProfile -ExecutionPolicy Bypass -File fleet\Invoke-FleetCommand.ps1 `
  -Runners runner01,runner02 `
  -PrivateKey $env:USERPROFILE\.ssh\id_ed25519 `
  -Command "Get-Service docker,gitlab-runner"
```

Password prompts cannot work inside `Invoke-FleetCommand.ps1` background jobs.
Use `-PrivateKey` or `-KerberosAuth`.

## Log bundle

On a runner:

```powershell
C:\GitLab-Runner\scripts\Export-RunnerLogs.ps1
```

The bundle includes provisioning logs, job logs, maintenance logs, Docker
diagnostics, runner diagnostics, event logs, system info, and the golden version
stamp.

## Common failure paths

| Symptom | First place to check |
| --- | --- |
| VM deployed but no runner in GitLab | `install.log`, `.firstboot_failed`, guestinfo keys. |
| Runner service starts but jobs fail to pull private images | SYSTEM Docker login output in `install.log`, `registry_user`, `registry_pass`. |
| Disk fills on C: | data disk init and Docker data-root move in `install.log`; `daemon.json`. |
| Docker service fails with Error 1067 | `daemon.json` content dumped by Phase 2. |
| Fleet says degraded | service status, disk free C/E, runner verify, exporter services. |
| Health task noisy | `health-check.log` and Application event IDs `9005` to `9008`. |

## Manual first-boot fallback

For lab troubleshooting, first boot can read:

```json
{
  "runner_token": "glrt-...",
  "runner_hostname": "runner-lab-01",
  "registry_user": "token-name",
  "registry_pass": "token-value"
}
```

Place it at `C:\GitLab-Runner\firstboot.json`, then run the startup task script
manually as Administrator/SYSTEM-equivalent for testing. Remove the file after
debugging.
