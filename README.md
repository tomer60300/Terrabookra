# Terrabookra — GitLab Runner Golden Image (Windows)

Automated provisioning of GitLab Runner VMs for an air-gapped Windows Server 2019 environment.

A single PowerShell script (`Install-GitLabRunner.ps1`) is executed by VMware Aria (Be1) on a freshly provisioned VM and produces a fully operational GitLab Runner — registered, polling for jobs, with Docker, maintenance tasks, and monitoring — all with zero manual intervention.

---

## Stack

| Component | Version |
|-----------|---------|
| Host OS | Windows Server 2019 LTSC (Build 17763) |
| GitLab | 16.7.10-ee (self-managed) |
| GitLab Runner | 16.7.0 |
| Docker | 25.0.15 (raw binaries, process isolation) |
| Container images | Harbor `golden-image` project |
| Artifact store | MinIO S3 (`gitlab-runner-golden` bucket) |
| Provisioning | VMware Aria (Be1) |

---

## Repository Structure

```
Terrabookra/
├── Install-GitLabRunner.ps1      # Main 3-phase post-install script
├── scripts/                      # Maintenance scripts deployed to C:\GitLab-Runner\scripts
│   ├── health-check.ps1          # Service & disk health (every 5 min)
│   ├── docker-watchdog.ps1       # Auto-restart Docker if unresponsive (every 5 min)
│   ├── disk-monitor.ps1          # Emergency prune on low disk (every 30 min)
│   ├── kill-stale-containers.ps1 # Kill containers running > 4 hours (every 2 h)
│   └── Register-ScheduledTasks.ps1  # Creates all 10 scheduled tasks
├── binaries/                     # Executables downloaded from MinIO
│   ├── gitlab-runner-16.7.0-windows-amd64.exe
│   ├── docker/
│   │   ├── docker.exe
│   │   └── dockerd.exe
│   └── git/
│       └── MinGit-2.43.0-64-bit.zip
├── tools/                        # Utilities
│   ├── winrar-x64-701.exe
│   ├── nssm-2.24.zip
│   └── sysinternals/
│       ├── procexp64.exe
│       ├── Procmon64.exe
│       ├── handle64.exe
│       └── PSTools.zip
└── docs/
    ├── ARCHITECTURE.md           # System architecture and phase details
    └── INTERNET-PC-CHECKLIST.md  # Download list for USB transfer
```

---

## How It Works

The script runs in **three phases** with two reboots, managed by marker files:

1. **Phase 1** — System prep: disable services, power plan, pagefile, env vars, directory structure, install Containers + Hyper-V features. Reboot.
2. **Phase 2** — Docker: write `daemon.json`, download `docker.exe` + `dockerd.exe`, register `dockerd` as a Windows service. Reboot.
3. **Phase 3** — Runner: verify Docker, Defender exclusions, MinGit, runner binary, pre-pull Harbor images, write `config.toml`, register + start runner, deploy maintenance scripts, scheduled tasks, 17-check validation.

---

## Disk Layout

| Drive | Size | Purpose |
|-------|------|---------|
| `C:` | 100 GB | OS, runner binary, tools, scripts |
| `E:` | 1 TB | Docker data-root, pagefile, builds, cache |

If `E:` is not present, everything falls back to `C:`.

---

## Infrastructure Endpoints

| Service | URL |
|---------|-----|
| GitLab | `https://gitlab.kayhut.com` |
| Harbor | `https://harbor.kayhut.com` |
| MinIO S3 API | `https://kayhut-minio.com:9000` |
| MinIO Console | `https://kay-minio.kayhut.com:9001` |
| Artifactory | `https://artifactory-prod` |
| Be1 (VMware Aria) | `https://be1.kayhut.com` |

All services use self-signed certificates. TLS validation is bypassed throughout.

---

## MinIO Bucket Layout

All artifacts live in the `gitlab-runner-golden` bucket:

```
gitlab-runner-golden/
├── binaries/
│   ├── gitlab-runner-16.7.0-windows-amd64.exe
│   └── docker/
│       ├── docker.exe
│       └── dockerd.exe
├── binaries/git/
│   └── MinGit-2.43.0-64-bit.zip
├── scripts/
│   ├── health-check.ps1
│   ├── docker-watchdog.ps1
│   ├── disk-monitor.ps1
│   ├── kill-stale-containers.ps1
│   └── Register-ScheduledTasks.ps1
└── tools/
    ├── winrar-x64-701.exe
    ├── nssm-2.24.zip
    └── sysinternals/
        ├── procexp64.exe
        ├── Procmon64.exe
        ├── handle64.exe
        └── PSTools.zip
```

---

## Pre-pulled Container Images

These are pulled from Harbor during Phase 3:

- `harbor.kayhut.com/golden-image/gitlab-runner-helper:x86_64-v16.7.0-servercore1809`
- `harbor.kayhut.com/golden-image/servercore:ltsc2019`
- `harbor.kayhut.com/golden-image/windows:ltsc2019`

---

## Scheduled Maintenance Tasks

| Task | Schedule | Purpose |
|------|----------|---------|
| Docker-Image-Prune | Daily 03:00 | Remove unused images older than 7 days |
| Docker-Container-Cleanup | Every 4 h | Prune stopped containers |
| Docker-Stale-Container-Kill | Every 2 h | Kill containers running > 4 hours |
| Docker-Volume-Prune | Daily 03:30 | Prune orphan volumes |
| Docker-BuildCache-Prune | Weekly Sun 04:00 | Clear build cache |
| Runner-Workspace-Cleanup | Daily 04:00 | Delete build dirs older than 3 days |
| Disk-Space-Monitor | Every 30 min | Emergency prune if disk < 10 GB |
| Docker-Daemon-Watchdog | Every 5 min | Restart Docker if unresponsive |
| Runner-Service-Watchdog | Every 5 min | Restart Runner if stopped |
| Log-Rotation | Weekly Sun 05:00 | Rotate logs larger than 50 MB |

---

## Configuration

Edit the `$Script:Config` block at the top of `Install-GitLabRunner.ps1`:

- **MinIO credentials** — `MinioAccessKey` / `MinioSecretKey`
- **Harbor credentials** — `HarborUser` / `HarborPass`
- **Concurrency** — `ConcurrentJobs` (default: 2)
- **Runner token** — injected by Be1 as `GITLAB_RUNNER_TOKEN` env var

---

## Event Log IDs

All events are written to the Application log under source `GitLabRunner`:

| ID | Level | Meaning |
|----|-------|---------|
| 9001 | Error | Critical disk — emergency prune executed |
| 9002 | Warning | Low disk space warning |
| 9003 | Error | Docker daemon restarted by watchdog |
| 9004 | Warning | Runner service restarted by watchdog |
| 9005 | Error | Docker daemon unresponsive (health check) |
| 9006 | Error | Runner service not running (health check) |
| 9007 | Warning | Low disk space (health check) |
| 9008 | Warning | Stale containers detected |
| 9009 | Error | Docker restart failed |
| 9010 | Warning | Final validation — some checks failed |
| 9011 | Info | Final validation — all checks passed |
| 9012 | Warning | Stale containers killed |
