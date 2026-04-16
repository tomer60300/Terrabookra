# Architecture

## Overview

Terrabookra provisions GitLab Runner VMs in a fully air-gapped Windows Server 2019 environment. The project follows a **manager/worker modular design** — the orchestrator loads libraries and dispatches to focused phase scripts.

```
Be1 (VMware Aria) provisions VM
        │
        ▼
  Domain join + DNS config (handled by Be1/Bukra)
        │
        ▼
  Install-GitLabRunner.ps1 (orchestrator)
        │
        ├── dot-source lib/Config.ps1
        ├── dot-source lib/Common.ps1
        ├── dot-source phases/*.ps1
        ├── dot-source validation/*.ps1
        │
        ├── Phase 1: phases/Phase1-SystemPrep.ps1 ────► REBOOT
        │                                                  │
        ├── Phase 2: phases/Phase2-DockerInstall.ps1 ──► REBOOT
        │                                                  │
        └── Phase 3: phases/Phase3-RunnerSetup.ps1 ───► DONE
                         └── validation/Invoke-FinalValidation.ps1
```

---

## Module Dependency Map

```
Install-GitLabRunner.ps1 (orchestrator)
    │
    ├── lib/Config.ps1          ← loaded first (no dependencies)
    ├── lib/Common.ps1          ← depends on Config.ps1 ($Script:Config)
    │
    ├── phases/Phase1-SystemPrep.ps1      ← uses Common.ps1 functions
    ├── phases/Phase2-DockerInstall.ps1   ← uses Common.ps1 functions
    ├── phases/Phase3-RunnerSetup.ps1     ← uses Common.ps1 + calls Invoke-FinalValidation
    │
    └── validation/Invoke-FinalValidation.ps1  ← uses Common.ps1 + Config.ps1
```

All files are dot-sourced into the same scope by the orchestrator. They share `$Script:Config` and all functions from `Common.ps1`.

---

## Phase Detection

The orchestrator is re-run from the top after each reboot. Marker files determine where to resume:

| Marker | Location | Meaning |
|--------|----------|---------|
| `.phase1_complete` | `C:\GitLab-Runner\` | Phase 1 done → start Phase 2 |
| `.phase2_complete` | `C:\GitLab-Runner\` | Phase 2 done → start Phase 3 |
| No markers | — | Fresh start → run Phase 1 |

Markers older than 60 minutes are treated as stale and the phase is re-run.

---

## Phase 1: System Preparation (`phases/Phase1-SystemPrep.ps1`)

| Step | Action |
|------|--------|
| 1.1 | Register `GitLabRunner` Event Log source |
| 1.2 | Disable 17 unnecessary Windows services |
| 1.3 | Set High Performance power plan |
| 1.4 | Configure pagefile on data drive (capped at 32 GB) |
| 1.5 | Enable long paths, tune TCP stack, disable animations |
| 1.6 | Set env vars (`GIT_SSL_NO_VERIFY`, `DOTNET_CLI_TELEMETRY_OPTOUT`) + PATH |
| 1.7 | Create directory structure on C: and E: drives |
| 1.8 | Increase Event Log sizes (100 MB App/System, 50 MB Security) |
| 1.9 | Install Containers + Hyper-V Windows features |

---

## Phase 2: Docker Installation (`phases/Phase2-DockerInstall.ps1`)

| Step | Action |
|------|--------|
| 2.1 | Write `daemon.json` with insecure registries, process isolation, data-root on E:, DNS |
| 2.2 | Download `docker.exe` + `dockerd.exe` from MinIO |
| 2.3 | Register `dockerd` as a Windows service (`dockerd --register-service`) |

Docker 25.0.15 is installed from raw binaries — not via Mirantis Container Runtime installer.

---

## Phase 3: Runner Setup (`phases/Phase3-RunnerSetup.ps1`)

| Step | Action |
|------|--------|
| 3.1 | Verify Docker daemon (12 attempts, 10s apart) |
| 3.2 | Add Defender exclusions for runner, Docker, and build paths |
| 3.3 | Extract MinGit to `C:\GitLab-Runner\git\` |
| 3.4 | Download `gitlab-runner.exe` from MinIO |
| 3.5 | Docker login to Harbor + pre-pull 3 images |
| 3.6 | Generate `config.toml` (docker-windows executor, process isolation) |
| 3.7 | Register runner with GitLab (`--non-interactive --token`) |
| 3.8 | Install runner as Windows service (idempotent stop→uninstall→install→start) |
| 3.9 | Deploy 5 maintenance scripts from MinIO |
| 3.10 | Register 10 scheduled tasks |
| 3.11 | Deploy tools (WinRAR, NSSM, SysInternals) |
| 3.12 | Final validation (17 checks via `validation/Invoke-FinalValidation.ps1`) |

---

## Troubleshooting by Module

When something fails, the install log (`C:\GitLab-Runner\logs\install.log`) shows the step number. Here's where to look:

| Log shows | File to check |
|-----------|--------------|
| `[ERROR]` during 1.x steps | `phases/Phase1-SystemPrep.ps1` |
| `[ERROR]` during 2.x steps | `phases/Phase2-DockerInstall.ps1` |
| `[ERROR]` during 3.x steps | `phases/Phase3-RunnerSetup.ps1` |
| `[FAIL]` in validation | `validation/Invoke-FinalValidation.ps1` |
| S3 download failures | `lib/Common.ps1` → `Get-S3Object` |
| Config values wrong | `lib/Config.ps1` |
| Phase stuck / re-running | Check marker files in `C:\GitLab-Runner\` |

---

## Network Topology

```
┌──────────────────────────────────────────────────────────┐
│                   AIR-GAPPED NETWORK                     │
│                                                          │
│  ┌─────────┐   ┌────────┐   ┌───────┐   ┌───────────┐  │
│  │ GitLab  │   │ Harbor │   │ MinIO │   │    Be1    │  │
│  │ :443    │   │ :443   │   │ :9000 │   │ (Aria)    │  │
│  └────┬────┘   └───┬────┘   └───┬───┘   └─────┬─────┘  │
│       │            │            │              │         │
│       └────────────┴────────────┴──────────────┘         │
│                         │                                │
│                    Runner VMs                            │
│              (Windows Server 2019)                       │
│                                                          │
│                   ╔═══════════╗                           │
│                   ║ Internet  ║                           │
│                   ║    PC     ║ ← USB transfer only      │
│                   ╚═══════════╝                           │
└──────────────────────────────────────────────────────────┘
```

---

## Artifact Sources

| Artifact Type | Source | Protocol |
|---------------|--------|----------|
| Runner binary, Docker binaries, MinGit, tools | MinIO (`gitlab-runner-golden` bucket) | HTTPS + AWS Sig V4 |
| Container images (base, helper) | Harbor (`golden-image` project) | Docker pull (insecure registry) |
| Runner token | Be1 (injected as `GITLAB_RUNNER_TOKEN` env var) | — |

---

## Validation Checks (`validation/Invoke-FinalValidation.ps1`)

| # | Check |
|---|-------|
| 1 | OS Build = 17763 |
| 2 | Containers feature installed |
| 3 | Hyper-V feature installed |
| 4 | Docker service running |
| 5 | Docker version = 25.0.x |
| 6 | Docker isolation = process |
| 7 | Runner binary valid (PE header) |
| 8 | Runner service running |
| 9 | Runner verify (is alive) |
| 10 | Git available |
| 11 | GIT_SSL_NO_VERIFY set |
| 12 | Defender exclusions applied |
| 13 | Helper image present |
| 14 | Scheduled tasks >= 8 |
| 15 | Power plan = High Performance |
| 16 | Long paths enabled |
| 17 | Disk free >= 50 GB |
