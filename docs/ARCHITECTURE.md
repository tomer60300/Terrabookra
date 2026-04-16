# Architecture

## Overview

Terrabookra provisions GitLab Runner VMs in a fully air-gapped Windows Server 2019 environment. The provisioning flow is:

```
Be1 (VMware Aria) provisions VM
        │
        ▼
  Domain join + DNS config (handled by Be1/Bukra)
        │
        ▼
  Install-GitLabRunner.ps1 runs as Administrator
        │
        ├── Phase 1: System Prep ──────────► REBOOT
        │                                       │
        ├── Phase 2: Docker Install ───────► REBOOT
        │                                       │
        └── Phase 3: Runner + Validation ──► DONE (runner polling for jobs)
```

---

## Phase Detection

The script is re-run from the top after each reboot. Marker files determine where to resume:

| Marker | Location | Meaning |
|--------|----------|---------|
| `.phase1_complete` | `C:\GitLab-Runner\` | Phase 1 done, start Phase 2 |
| `.phase2_complete` | `C:\GitLab-Runner\` | Phase 2 done, start Phase 3 |
| No markers | — | Fresh start, run Phase 1 |

Markers older than 60 minutes are treated as stale and the phase is re-run.

---

## Phase 1: System Preparation

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

## Phase 2: Docker Installation

| Step | Action |
|------|--------|
| 2.1 | Write `daemon.json` with insecure registries, process isolation, data-root on E:, DNS |
| 2.2 | Download `docker.exe` + `dockerd.exe` from MinIO |
| 2.3 | Register `dockerd` as a Windows service (`dockerd --register-service`) |

Docker 25.0.15 is installed from raw binaries — not via Mirantis Container Runtime installer.

---

## Phase 3: Runner Setup

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
| 3.12 | Run 17-check final validation |

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

## Validation Checks (Phase 3.12)

1. OS Build = 17763
2. Containers feature installed
3. Hyper-V feature installed
4. Docker service running
5. Docker version = 25.0.x
6. Docker isolation = process
7. Runner binary valid (PE header)
8. Runner service running
9. Runner verify (is alive)
10. Git available
11. GIT_SSL_NO_VERIFY set
12. Defender exclusions applied
13. Helper image present
14. Scheduled tasks >= 8
15. Power plan = High Performance
16. Long paths enabled
17. Disk free >= 50 GB
