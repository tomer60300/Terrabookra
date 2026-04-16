# Changelog

All notable changes to the Terrabookra project are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)

---

## [2.1.0] — 2026-04-16

### Added — 6 new features

1. **Certificate import** (`scripts/Import-Certificates.ps1`)
   - Imports `.crt/.cer/.pem` files from `C:\GitLab-Runner\certs\` into Local Machine Trusted Root store
   - Skips already-trusted certs, logs thumbprints
   - TLS bypasses remain as fallback (belt and suspenders)

2. **Remote PowerShell** (`scripts/Enable-RemotePowerShell.ps1`)
   - Enables WinRM PSRemoting with auto-start
   - Configures TrustedHosts, firewall rules, memory limits
   - Integrated into Phase 1 (step 1.11)

3. **OpenCode Desktop** (`tools/opencode/opencode.jsonc`)
   - Config template for air-gapped environment
   - S3 key added for Windows installer download
   - Added to Internet PC checklist

4. **Network connectivity monitor** (`scripts/Test-NetworkConnectivity.ps1`)
   - Tests TCP to GitLab, Harbor, MinIO, Artifactory, Be1 every 2 minutes
   - Daily CSV logs with timestamp + latency for correlation with job failures
   - 30-day auto-rotation

5. **Job wrapper logging** (`scripts/Write-JobLog.ps1`)
   - `pre_build_script` / `post_build_script` in config.toml
   - Logs job start/end with: timestamp, job name, ID, pipeline, user, status, duration
   - Daily files with 30-day rotation

6. **RDP audit log** (`scripts/Export-RdpAuditLog.ps1`)
   - Parses TerminalServices + Security event logs for RDP sessions
   - Logs: timestamp, IP, username, logon/logoff/disconnect/reconnect
   - Runs every 5 minutes, 30-day rotation
   - Audit policy enabled in Phase 1 (step 1.12)

### Changed
- `lib/Config.ps1` — added CertsDir, JobLogDir, NetLogDir, RdpLogDir, MonitorHosts, S3KeysExtra
- `phases/Phase1-SystemPrep.ps1` — added steps 1.10 (certs), 1.11 (WinRM), 1.12 (audit policy)
- `phases/Phase3-RunnerSetup.ps1` — deploys new scripts, creates log subdirectories, job wrapper in config.toml
- `scripts/Register-ScheduledTasks.ps1` — 10 → 12 tasks (+ Network-Connectivity-Monitor, RDP-Audit-Logger)
- `config.toml` template — added `pre_build_script` and `post_build_script` for job logging

---

## [2.0.0] — 2026-04-16

### Changed
- **BREAKING: Modular refactor** — `Install-GitLabRunner.ps1` is now a slim orchestrator (~80 lines)
  that dot-sources focused modules instead of containing all logic in one 823-line file
- Split into manager/worker pattern:
  - `lib/Config.ps1` — all configuration in one place
  - `lib/Common.ps1` — shared helpers (TLS, logging, S3, PE validation, phase markers, reboot)
  - `phases/Phase1-SystemPrep.ps1` — system preparation
  - `phases/Phase2-DockerInstall.ps1` — Docker installation
  - `phases/Phase3-RunnerSetup.ps1` — runner setup, maintenance, tools
  - `validation/Invoke-FinalValidation.ps1` — 17-check validation suite

### Added
- `lib/` directory for shared libraries
- `phases/` directory with one file per phase
- `validation/` directory for the validation suite
- Folder READMEs for `lib/`, `phases/`, `validation/`
- Module dependency map in ARCHITECTURE.md
- Troubleshooting-by-module guide in ARCHITECTURE.md

### Why
- Easier to debug on air-gapped VMs — log step numbers point to exact files
- Each module has single responsibility and clear boundaries
- Configuration changes are isolated to `lib/Config.ps1`
- Phases can be tested independently

---

## [1.0.0] — 2026-04-16

### Added
- Initial repository setup with full project structure
- `Install-GitLabRunner.ps1` — three-phase post-install script for Be1 (VMware Aria)
  - Phase 1: System prep, services, env vars, Windows features (Containers + Hyper-V)
  - Phase 2: Docker 25.0.15 raw binary install, `daemon.json`, `dockerd` service registration
  - Phase 3: Runner install, registration, config.toml, image pre-pull, maintenance, 17-check validation
- Maintenance scripts with proper headers, logging, and event log integration:
  - `health-check.ps1` — service and disk health monitoring
  - `docker-watchdog.ps1` — auto-restart Docker if unresponsive
  - `disk-monitor.ps1` — emergency prune on critically low disk
  - `kill-stale-containers.ps1` — kill CI containers running > 4 hours
  - `Register-ScheduledTasks.ps1` — creates all 10 scheduled tasks
- Binaries:
  - `gitlab-runner-16.7.0-windows-amd64.exe`
  - `docker.exe` + `dockerd.exe` (Docker 25.0.15)
  - `MinGit-2.43.0-64-bit.zip`
- Tools:
  - `winrar-x64-701.exe`, `nssm-2.24.zip`
  - SysInternals: `procexp64.exe`, `Procmon64.exe`, `handle64.exe`, `PSTools.zip`
- Documentation:
  - `README.md` — project overview, structure, configuration
  - `docs/ARCHITECTURE.md` — system architecture and phase details
  - `docs/INTERNET-PC-CHECKLIST.md` — download list for USB transfer into air-gapped network
  - Folder READMEs for `scripts/`, `binaries/`, `tools/`

### Notes
- Docker Phase 2 uses raw zip binaries (docker.exe + dockerd.exe) — NOT Mirantis installer
- All TLS validation bypassed (self-signed certs, air-gapped network)
- MinIO credentials are placeholder — replace before deployment
