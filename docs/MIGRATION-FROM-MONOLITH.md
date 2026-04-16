# Migration from Monolith — What Changed

This document describes every structural and functional difference between the original
single-file `Install-GitLabRunner.ps1` (822 lines) and the current modular project (1917 lines across 17 `.ps1` files).

---

## Structure: Before vs After

### Before (v1 — single file)

```
Install-GitLabRunner.ps1    ← 822 lines, everything in one file
scripts/
  health-check.ps1          ← already existed (deployed from S3)
  disk-monitor.ps1
  docker-watchdog.ps1
  kill-stale-containers.ps1
  Register-ScheduledTasks.ps1
```

Everything was in the monolith: configuration, TLS bypass, logging, S3 download,
PE validation, service helpers, phase markers, reboot logic, all 3 phases,
inline scheduled task fallback, and the 17-check validation suite.

### After (v2.1.1 — modular)

```
Install-GitLabRunner.ps1              ← 92 lines — orchestrator only
lib/
  Config.ps1                          ← 154 lines — all settings and S3 keys
  Common.ps1                          ← 280 lines — TLS, logging, S3, helpers
phases/
  Phase1-SystemPrep.ps1               ← 153 lines — system prep + 3 new steps
  Phase2-DockerInstall.ps1            ← 97 lines  — Docker install
  Phase3-RunnerSetup.ps1              ← 273 lines — runner + maintenance + tools
validation/
  Invoke-FinalValidation.ps1          ← 79 lines  — 17-check suite
scripts/
  (5 original scripts — unchanged)
  Import-Certificates.ps1             ← NEW — S3 cert fetch + import
  Enable-RemotePowerShell.ps1         ← NEW — WinRM setup
  Test-NetworkConnectivity.ps1        ← NEW — TCP probe logger
  Write-JobLog.ps1                    ← NEW — CI job start/end wrapper
  Export-RdpAuditLog.ps1              ← NEW — RDP session audit
tools/
  opencode/opencode.jsonc             ← NEW — air-gapped OpenCode config
docs/
  ARCHITECTURE.md
  DEPENDENCIES.md
  INTERNET-PC-CHECKLIST.md
  MIGRATION-FROM-MONOLITH.md          ← this file
CHANGELOG.md
.gitignore
```

---

## What Was Extracted (no logic changes)

These sections were lifted verbatim from the monolith into dedicated files.
The code is identical — only the file boundary changed.

| Monolith Section | Extracted To | Lines |
|---|---|---|
| `$Script:Config = @{...}` (lines 34–121) | `lib/Config.ps1` | 154 |
| TLS bypass + logging + Get-S3Object + PE helpers + service helpers + phase markers + reboot (lines 134–344) | `lib/Common.ps1` | 280 |
| `Invoke-Phase1` function (lines 350–451) | `phases/Phase1-SystemPrep.ps1` | 153 |
| `Invoke-Phase2` function (lines 457–522) | `phases/Phase2-DockerInstall.ps1` | 97 |
| `Invoke-Phase3` + `Register-InlineScheduledTask` (lines 528–748) | `phases/Phase3-RunnerSetup.ps1` | 273 |
| `Invoke-FinalValidation` (lines 754–792) | `validation/Invoke-FinalValidation.ps1` | 79 |
| Main dispatcher (lines 798–822) | `Install-GitLabRunner.ps1` (orchestrator) | 92 |

The orchestrator now does three things: resolve `$PSScriptRoot`, dot-source
all modules, and dispatch to the right phase based on marker files.

---

## What Was Added (new functionality)

These features did not exist in the monolith.

### 1. Certificate Import from S3 (`Import-Certificates.ps1`)

**Monolith**: No certificate handling at all.

**Now**: Phase 1 step 1.10 runs `Import-Certificates.ps1` which:
1. Downloads `.crt` files from MinIO S3 (`$Config.S3Certs` array) to `C:\GitLab-Runner\certs\`
2. Imports all `.crt/.cer/.pem` found in that directory into `Cert:\LocalMachine\Root`
3. Skips already-trusted certs (by thumbprint)
4. Logs to Windows Event Log (Event IDs 9020, 9021, 9022)

TLS bypasses (`TrustAllCerts` + `GIT_SSL_NO_VERIFY`) remain as fallback — this is belt-and-suspenders.

**New S3 objects needed**: `certs/kayhut-ca.crt`

### 2. Remote PowerShell (`Enable-RemotePowerShell.ps1`)

**Monolith**: No WinRM setup. SSH/RDP-only access.

**Now**: Phase 1 step 1.11 runs `Enable-RemotePowerShell.ps1` which:
- Enables PSRemoting (force, skip network profile check)
- Sets WinRM to auto-start
- Configures TrustedHosts (`*` by default)
- Opens firewall TCP 5985 + 5986
- Sets MaxMemoryPerShellMB to 2048

After provisioning, connect with:
```powershell
Enter-PSSession -ComputerName <runner-hostname> -Credential (Get-Credential)
```

### 3. RDP Audit Logging (`Export-RdpAuditLog.ps1`)

**Monolith**: No RDP tracking.

**Now**: Phase 1 step 1.12 enables audit policy (`auditpol /set /subcategory:"Logon" /success:enable /failure:enable`). Then a scheduled task (every 5 min) runs `Export-RdpAuditLog.ps1` which:
- Parses TerminalServices Event IDs 21 (logon), 23 (logoff), 24 (disconnect), 25 (reconnect)
- Parses Security Event ID 4624 Type 10 (backup source)
- Uses incremental marker file to avoid reprocessing
- Writes daily log to `C:\GitLab-Runner\logs\rdp\rdp-YYYY-MM-DD.log`
- 30-day auto-rotation

### 4. Network Connectivity Monitor (`Test-NetworkConnectivity.ps1`)

**Monolith**: No network monitoring.

**Now**: Scheduled task (every 2 min) runs `Test-NetworkConnectivity.ps1` which:
- TCP probes to 5 hosts: GitLab (443), Harbor (443), MinIO (9000), Artifactory (443), Be1 (443)
- Writes daily CSV: `C:\GitLab-Runner\logs\network\net-YYYY-MM-DD.csv`
- Columns: `Timestamp,Host,Port,Success,LatencyMs,Error`
- 30-day auto-rotation

Use for debugging CI timeouts:
```powershell
Import-Csv C:\GitLab-Runner\logs\network\net-2026-04-16.csv |
    Where-Object { $_.Timestamp -gt '2026-04-16T14:00' -and $_.Success -eq 'False' }
```

### 5. CI Job Wrapper Logging (`Write-JobLog.ps1`)

**Monolith**: No job tracking on the host.

**Now**: config.toml includes `pre_build_script` and `post_build_script` that call `Write-JobLog.ps1`:
- `start` action: logs job info + stores start timestamp in `%TEMP%`
- `end` action: calculates duration from stored timestamp, logs final status
- Daily log: `C:\GitLab-Runner\logs\jobs\jobs-YYYY-MM-DD.log`
- 30-day auto-rotation
- Uses CI env vars: `CI_JOB_ID`, `CI_JOB_NAME`, `CI_PROJECT_NAME`, `CI_PIPELINE_ID`, `GITLAB_USER_LOGIN`, `CI_JOB_STATUS`

### 6. OpenCode Configuration (`tools/opencode/opencode.jsonc`)

**Monolith**: No OpenCode.

**Now**: Air-gapped OpenCode config template with Anthropic provider + custom instructions for the environment. Deployed to `%USERPROFILE%\.config\opencode.jsonc`.

**New S3 objects needed**: `tools/opencode/opencode-desktop-windows-x64-setup.exe` + `tools/opencode/opencode.jsonc`

---

## Config Changes (Config.ps1 vs monolith)

### New keys in v2.1.1 that the monolith did NOT have

```powershell
# Certificate handling
CertsDir         = 'C:\GitLab-Runner\certs'
S3Certs          = @('certs/kayhut-ca.crt')

# Job logging
JobLogDir        = 'C:\GitLab-Runner\logs\jobs'
JobLogMaxDays    = 30

# Network monitoring
NetLogDir        = 'C:\GitLab-Runner\logs\network'
NetLogMaxDays    = 30
MonitorHosts     = @(
    @{ Host = 'gitlab.kayhut.com';  Port = 443  },
    @{ Host = 'harbor.kayhut.com';  Port = 443  },
    @{ Host = 'kayhut-minio.com';   Port = 9000 },
    @{ Host = 'artifactory-prod';   Port = 443  },
    @{ Host = 'be1.kayhut.com';     Port = 443  }
)

# RDP audit
RdpLogDir        = 'C:\GitLab-Runner\logs\rdp'
RdpLogMaxDays    = 30

# Additional S3 keys (7 new scripts + 2 OpenCode)
S3KeysExtra      = @{ ImportCerts, EnableRemotePS, NetMonitor, JobLog, RdpAudit, OpenCodeExe, OpenCodeConfig }
```

### config.toml changes

The monolith generated a config.toml without job logging hooks.
Now it includes:

```toml
pre_build_script = "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\GitLab-Runner\\scripts\\Write-JobLog.ps1 -Action start"
post_build_script = "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\GitLab-Runner\\scripts\\Write-JobLog.ps1 -Action end"
```

---

## Scheduled Tasks: Before vs After

| Task | Monolith | Now | Interval |
|---|---|---|---|
| Docker-Image-Prune | Yes | Yes | Daily 03:00 |
| Docker-Container-Cleanup | Yes | Yes | Every 4h |
| Docker-Stale-Container-Kill | Yes | Yes | Every 2h |
| Docker-Volume-Prune | Yes | Yes | Daily 03:30 |
| Docker-BuildCache-Prune | Yes | Yes | Weekly Sun 04:00 |
| Runner-Workspace-Cleanup | Yes | Yes | Daily 04:00 |
| Disk-Space-Monitor | Yes | Yes | Every 30 min |
| Docker-Daemon-Watchdog | Yes | Yes | Every 5 min |
| Runner-Service-Watchdog | Yes | Yes | Every 5 min |
| Log-Rotation | Yes | Yes | Weekly Sun 05:00 |
| **Network-Connectivity-Monitor** | **No** | **Yes** | Every 2 min |
| **RDP-Audit-Logger** | **No** | **Yes** | Every 5 min |

Total: 10 → 12

---

## S3 Objects: Before vs After

| Category | Monolith Count | Now Count | Delta |
|---|---|---|---|
| Binaries (Docker, Runner, Git) | 4 | 4 | — |
| Certificates | 0 | 1 | +1 |
| Scripts (maintenance) | 5 | 10 | +5 |
| Tools (WinRAR, NSSM, SysInternals) | 6 | 6 | — |
| OpenCode | 0 | 2 | +2 |
| **Total** | **15** | **23** | **+8** |

---

## Phase 1 Steps: Before vs After

| Step | Monolith | Now |
|---|---|---|
| 1.1 Register Event Log source | Yes | Yes |
| 1.2 Disable unnecessary services | Yes | Yes |
| 1.3 High Performance power plan | Yes | Yes |
| 1.4 Configure pagefile | Yes | Yes |
| 1.5 Network tuning + long paths | Yes | Yes |
| 1.6 Environment variables + PATH | Yes | Yes |
| 1.7 Create directory structure | Yes | Yes |
| 1.8 Event Log sizes | Yes | Yes |
| 1.9 Windows Features (Containers, Hyper-V) | Yes | Yes |
| **1.10 Import self-signed certificates** | **No** | **Yes** |
| **1.11 Enable WinRM** | **No** | **Yes** |
| **1.12 Enable RDP audit policy** | **No** | **Yes** |

---

## Event IDs: Before vs After

| Event ID | Description | Monolith | Now |
|---|---|---|---|
| 9001 | Critical disk space, emergency prune | Yes | Yes |
| 9002 | Low disk space warning | Yes | Yes |
| 9003 | Docker daemon restarted | Yes | Yes |
| 9004 | Runner service restarted by watchdog | Yes | Yes |
| 9005 | Docker daemon unresponsive | Yes | Yes |
| 9006 | Runner service not running | Yes | Yes |
| 9007 | Low disk space (<20 GB) | Yes | Yes |
| 9008 | Stale containers detected | Yes | Yes |
| 9009 | Docker restart failed | Yes | Yes |
| 9010 | Validation: checks failed | Yes | Yes |
| 9011 | Validation: all passed | Yes | Yes |
| 9012 | Stale containers killed | Yes | Yes |
| **9020** | **Certificate imported** | **No** | **Yes** |
| **9021** | **Certificate import failed** | **No** | **Yes** |
| **9022** | **Certificate S3 download failed** | **No** | **Yes** |

---

## Log Files: Before vs After

| Log File | Monolith | Now |
|---|---|---|
| `logs/install.log` | Yes | Yes |
| `logs/health-check.log` | Yes | Yes |
| `logs/disk-monitor.log` | Yes | Yes |
| `logs/docker-watchdog.log` | Yes | Yes |
| `logs/stale-containers.log` | Yes | Yes |
| `logs/image-prune.log` | Yes | Yes |
| `logs/container-prune.log` | Yes | Yes |
| `logs/volume-prune.log` | Yes | Yes |
| `logs/buildcache-prune.log` | Yes | Yes |
| **`logs/jobs/jobs-YYYY-MM-DD.log`** | **No** | **Yes** |
| **`logs/network/net-YYYY-MM-DD.csv`** | **No** | **Yes** |
| **`logs/rdp/rdp-YYYY-MM-DD.log`** | **No** | **Yes** |

---

## Dot-Source Chain (How Modules Load)

```
Install-GitLabRunner.ps1
  ├── . lib\Config.ps1           → defines $Script:Config
  ├── . lib\Common.ps1           → TLS, Write-Log, Get-S3Object, helpers
  ├── . phases\Phase1-SystemPrep.ps1   → Invoke-Phase1
  ├── . phases\Phase2-DockerInstall.ps1→ Invoke-Phase2
  ├── . phases\Phase3-RunnerSetup.ps1  → Invoke-Phase3
  └── . validation\Invoke-FinalValidation.ps1 → Invoke-FinalValidation
```

All scripts share `$Script:Config` and all functions from `Common.ps1`.
Phase scripts call each other via `Invoke-Phase2` / `Invoke-Phase3` when no reboot is needed.
Feature scripts (`Import-Certificates.ps1`, etc.) are called with `&` (invoke operator) inside the phase functions.
