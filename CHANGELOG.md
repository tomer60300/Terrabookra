# Changelog

All notable changes to the Terrabookra project are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)

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
