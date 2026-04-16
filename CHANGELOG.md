# Changelog

All notable changes to the Terrabookra project are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)

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
