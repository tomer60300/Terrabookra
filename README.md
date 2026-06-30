# Terrabookra — GitLab Runner Golden Image (Windows)

Automated provisioning of GitLab Runner VMs for an air-gapped Windows Server 2019 environment.

> **`terraform` branch:** runner deployment is now the infra_tf-compatible **Aria Service Broker
> catalog path**. Terraform `1.0.5` uses `vmware/vra` `0.17.2` from the offline mirror, requests an
> existing Windows-runner catalog item, and passes string-only `vm_inputs`. The Aria CSP refresh token
> is supplied only through `TF_VAR_vra_refresh_token`. The old Packer/vSphere spike remains in the tree
> as historical work, but it is no longer the CI deploy path for runners. `main` remains the Be1 rollback
> baseline and matches the older description below.
> See `docs/MIGRATION-TO-TERRAFORM.md` + `docs/MIGRATION-STATUS.md`.

On `main`, a single orchestrator (`Bootstrap-GitLabRunner.ps1`) is executed by VMware Aria (Be1) on a
freshly provisioned VM and dispatches modular phases that produce a fully operational GitLab Runner.

---

## Stack

| Component | Version |
|-----------|---------|
| Host OS | Windows Server 2019 LTSC (Build 17763) |
| GitLab | 16.7.10-ee (self-managed) |
| GitLab Runner | 16.7.0 |
| Docker | 25.0.15 (raw binaries, process isolation) |
| Container images | GitLab Container Registry (`terraform` branch; Harbor on `main`) |
| Artifact store | Git LFS + uploaded repo (`terraform` branch; MinIO S3 on `main`) |
| Build / deploy | Aria Service Broker catalog via Terraform (`terraform` branch; VMware Aria/Be1 on `main`) |

---

## Repository Structure

```
Terrabookra/
├── Bootstrap-GitLabRunner.ps1              # Orchestrator: load modules, detect phase, dispatch
│
├── lib/                                  # Shared libraries (dot-sourced by orchestrator)
│   ├── Config.ps1                        # All settings, paths, S3 keys, constants
│   └── Common.ps1                        # TLS bypass, logging, S3 download, PE validation,
│                                         #   phase markers, reboot, service helpers
│
├── phases/                               # One file per phase — self-contained logic
│   ├── Phase1-SystemPrep.ps1             # Services, power, pagefile, env, dirs, Windows features
│   ├── Phase2-DockerInstall.ps1          # daemon.json, Docker binaries, dockerd service
│   └── Phase3-RunnerSetup.ps1            # Docker verify, runner, images, config, maintenance, tools
│
├── validation/
│   └── Invoke-FinalValidation.ps1        # 17-check validation suite
│
├── scripts/                              # Maintenance scripts (deployed to C:\GitLab-Runner\scripts)
│   ├── health-check.ps1                  # Service & disk health (every 5 min)
│   ├── docker-watchdog.ps1               # Auto-restart Docker if unresponsive (every 5 min)
│   ├── disk-monitor.ps1                  # Emergency prune on low disk (every 30 min)
│   ├── kill-stale-containers.ps1         # Kill containers running > 4 hours (every 2 h)
│   └── Register-ScheduledTasks.ps1       # Creates all 10 scheduled tasks
│
├── binaries/                             # README only (stored in MinIO, not Git)
├── tools/                                # README only (stored in MinIO, not Git)
│
├── docs/
│   ├── ARCHITECTURE.md                   # System architecture and phase details
│   └── INTERNET-PC-CHECKLIST.md          # Download list for USB transfer
│
└── CHANGELOG.md
```

---

## Modular Design

The project follows a **manager/worker pattern**. The orchestrator (`Bootstrap-GitLabRunner.ps1`) is compact — it loads libraries and dispatches to the correct phase. Each module has a single responsibility:

| File | Responsibility | Lines |
|------|---------------|-------|
| `Bootstrap-GitLabRunner.ps1` | Load modules, detect phase, dispatch | ~80 |
| `lib/Config.ps1` | All configuration in one place | ~100 |
| `lib/Common.ps1` | Shared helpers (S3, logging, TLS, etc.) | ~200 |
| `phases/Phase1-SystemPrep.ps1` | System preparation | ~100 |
| `phases/Phase2-DockerInstall.ps1` | Docker installation | ~80 |
| `phases/Phase3-RunnerSetup.ps1` | Runner setup + maintenance | ~200 |
| `validation/Invoke-FinalValidation.ps1` | 17-check validation | ~60 |

**Why modular?** When something breaks on an air-gapped VM, you need to know exactly which file and which step failed. Each phase logs step numbers (1.1, 2.1, 3.1, etc.) so the install log tells you precisely where to look.

---

## How It Works

The orchestrator is re-run from the top after each Be1 reboot. Marker files determine where to resume:

```
Be1 runs Bootstrap-GitLabRunner.ps1
    │
    ├─ dot-source lib/Config.ps1        (settings)
    ├─ dot-source lib/Common.ps1        (helpers)
    ├─ dot-source phases/*.ps1          (phase functions)
    ├─ dot-source validation/*.ps1      (validation)
    │
    ├─ .phase2_complete exists? ──► Invoke-Phase3
    ├─ .phase1_complete exists? ──► Invoke-Phase2
    └─ No markers?             ──► Invoke-Phase1
```

1. **Phase 1** — System prep → reboot if Windows features needed
2. **Phase 2** — Docker install → reboot if dockerd not ready
3. **Phase 3** — Runner + maintenance + validation → done

---

## Disk Layout

| Drive | Size | Purpose |
|-------|------|---------|
| `C:` | 100 GB | OS, runner binary, tools, scripts |
| `E:` | 1 TB | Docker data-root, pagefile, builds, cache |

If `E:` is not present, everything falls back to `C:`.

---

## Configuration

Edit `lib/Config.ps1`:

- **MinIO credentials** — `MinioAccessKey` / `MinioSecretKey`
- **Harbor credentials** — `HarborUser` / `HarborPass`
- **Concurrency** — `ConcurrentJobs` (default: 2)
- **Runner token** — injected by Be1 as `GITLAB_RUNNER_TOKEN` env var

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

## Event Log IDs

All events → Application log, source `GitLabRunner`:

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
