# Architecture

## Overview

Terrabookra provisions GitLab Runner VMs in a fully air-gapped Windows Server 2019 environment. A single bootstrap script is the only file VMware Aria (Be1) fetches from MinIO -- it self-downloads the rest and orchestrates a 4-phase provisioning flow with two reboots.

```
                                     AIR-GAPPED NETWORK
  +---------------------------------------------------------------------+
  |                                                                     |
  |   +--------+     +---------+     +-------+     +---------+         |
  |   | GitLab |     | Harbor  |     | MinIO |     |   Be1   |         |
  |   |  :443  |     |  :443   |     | :9000 |     | (Aria)  |         |
  |   +---+----+     +----+----+     +---+---+     +----+----+         |
  |       |               |              |              |               |
  |       |               |              |              |               |
  |       |               |              |     1. Create VM             |
  |       |               |              |     2. Domain join + DNS     |
  |       |               |              |     3. Set RUNNER_TOKEN env  |
  |       |               |              |<----4. Fetch Bootstrap.ps1   |
  |       |               |              |     5. Trigger Bootstrap.ps1 |
  |       |               |              |              |               |
  |       |               |              |              v               |
  |       |               |              |    +-------------------+     |
  |       |               |              |    |  Runner VM        |     |
  |       |               |              +--->|  (Win Srv 2019)   |     |
  |       |               +------------------>|                   |     |
  |       +---------------------------------->|  Phase 0..3       |     |
  |       |               |              |    +-------------------+     |
  |       |               |              |                              |
  +---------------------------------------------------------------------+
                                         ^
                     +===========+       |
                     | Internet  |       | USB transfer only
                     |    PC     |-------+
                     +===========+
```

---

## Execution Flow (Detailed)

```
Be1 (VMware Aria)
  |
  |-- 1. Create VM (Windows Server 2019 LTSC)
  |-- 2. Join domain + DNS config
  |-- 3. Set env var: GITLAB_RUNNER_TOKEN = glrt-XXXX
  |-- 4. Fetch Bootstrap-GitLabRunner.ps1 from MinIO
  |-- 5. Trigger Bootstrap-GitLabRunner.ps1
  |       |
  |       v
  |   Bootstrap-GitLabRunner.ps1
  |       |
  |       |-- [Phase 0] Self-bootstrap from MinIO (embedded S3 client)
  |       |       |
  |       |       +-- MinIO: bootstrap/lib/Config.ps1               -> C:\GitLab-Runner\lib\
  |       |       +-- MinIO: bootstrap/lib/Common.ps1               -> C:\GitLab-Runner\lib\
  |       |       +-- MinIO: bootstrap/phases/Phase1-SystemPrep.ps1 -> C:\GitLab-Runner\phases\
  |       |       +-- MinIO: bootstrap/phases/Phase2-DockerInstall.ps1
  |       |       +-- MinIO: bootstrap/phases/Phase3-RunnerSetup.ps1
  |       |       +-- MinIO: bootstrap/validation/Invoke-FinalValidation.ps1
  |       |
  |       |-- dot-source lib/Config.ps1
  |       |-- dot-source lib/Common.ps1
  |       |-- dot-source phases/Phase1-SystemPrep.ps1
  |       |-- dot-source phases/Phase2-DockerInstall.ps1
  |       |-- dot-source phases/Phase3-RunnerSetup.ps1
  |       |-- dot-source validation/Invoke-FinalValidation.ps1
  |       |
  |       |-- Check marker files -> dispatch to correct phase
  |       |       No markers        -> Phase 1
  |       |       .phase1_complete  -> Phase 2
  |       |       .phase2_complete  -> Phase 3
  |       |
  |       |-- [Phase 1] System Preparation
  |       |       |
  |       |       +-- 1.0  Pre-flight: Test-Dependencies.ps1 (subprocess)
  |       |       |         +-- DNS resolve: gitlab, harbor, minio, artifactory, be1
  |       |       |         +-- S3 HEAD:    all 33 objects in MinIO bucket
  |       |       |         +-- Harbor API: v2 manifest check
  |       |       |
  |       |       +-- 1.1  Register Event Log source
  |       |       +-- 1.2  Disable 17 Windows services
  |       |       +-- 1.3  High Performance power plan
  |       |       +-- 1.4  Pagefile on data drive (E: or C:)
  |       |       +-- 1.5  Long paths + TCP tuning
  |       |       +-- 1.6  Env vars (GIT_SSL_NO_VERIFY, PATH)
  |       |       +-- 1.7  Create directory structure (C: + E:)
  |       |       +-- 1.8  Event Log sizes (100MB App/Sys, 50MB Sec)
  |       |       +-- 1.9  Install Windows Features (Containers + Hyper-V)
  |       |       +-- 1.10 Import-Certificates.ps1
  |       |       |         +-- MinIO: scripts/Import-Certificates.ps1  (fetch script)
  |       |       |         +-- MinIO: certs/kayhut-ca.crt              (fetch cert)
  |       |       +-- 1.11 Enable-RemotePowerShell.ps1
  |       |       |         +-- MinIO: scripts/Enable-RemotePowerShell.ps1
  |       |       +-- 1.12 Enable RDP audit policy
  |       |       |
  |       |       +-- Set marker: .phase1_complete
  |       |       +-- REBOOT (if features required it)
  |       |
  |-- 6. Be1 re-triggers Bootstrap-GitLabRunner.ps1 after reboot
  |       |
  |       |-- [Phase 0] Skip (files already on disk)
  |       |
  |       |-- [Phase 2] Docker Installation
  |       |       |
  |       |       +-- 2.1  Write daemon.json (insecure registries, process isolation)
  |       |       |         +-- Create docker-users group
  |       |       +-- 2.2  Download Docker binaries
  |       |       |         +-- MinIO: binaries/docker/docker.exe   -> C:\Program Files\Docker\
  |       |       |         +-- MinIO: binaries/docker/dockerd.exe  -> C:\Program Files\Docker\
  |       |       +-- 2.3  Register dockerd as Windows service
  |       |       |
  |       |       +-- Set marker: .phase2_complete
  |       |       +-- REBOOT (if Docker not yet running)
  |       |
  |-- 7. Be1 re-triggers Bootstrap-GitLabRunner.ps1 after reboot
  |       |
  |       |-- [Phase 0] Skip (files already on disk)
  |       |
  |       |-- [Phase 3] Runner Setup & Configuration
  |               |
  |               +-- 3.1  Verify Docker daemon (12 attempts, 10s apart)
  |               +-- 3.2  Defender exclusions (paths + processes)
  |               +-- 3.3  MinGit
  |               |         +-- MinIO: binaries/git/MinGit-2.43.0-64-bit.zip -> C:\GitLab-Runner\git\
  |               +-- 3.4  GitLab Runner binary
  |               |         +-- MinIO: binaries/gitlab-runner-16.7.0-windows-amd64.exe -> C:\GitLab-Runner\
  |               +-- 3.5  Pre-pull container images
  |               |         +-- Harbor: golden-image/gitlab-runner-helper:x86_64-v16.7.0-servercore1809
  |               |         +-- Harbor: golden-image/servercore:ltsc2019
  |               |         +-- Harbor: golden-image/windows:ltsc2019
  |               +-- 3.6  Resolve token (glrt- auth vs registration/PAT)
  |               +-- 3.7  Register runner with GitLab (if not glrt- token)
  |               |         +-- GitLab API: POST /api/v4/runners (registration)
  |               +-- 3.8  Write config.toml + install runner as Windows service
  |               +-- 3.9  Deploy maintenance scripts (12 scripts)
  |               |         +-- MinIO: scripts/health-check.ps1
  |               |         +-- MinIO: scripts/disk-monitor.ps1
  |               |         +-- MinIO: scripts/docker-watchdog.ps1
  |               |         +-- MinIO: scripts/kill-stale-containers.ps1
  |               |         +-- MinIO: scripts/Register-ScheduledTasks.ps1
  |               |         +-- MinIO: scripts/Import-Certificates.ps1
  |               |         +-- MinIO: scripts/Enable-RemotePowerShell.ps1
  |               |         +-- MinIO: scripts/Test-NetworkConnectivity.ps1
  |               |         +-- MinIO: scripts/Write-JobLog.ps1
  |               |         +-- MinIO: scripts/Export-RdpAuditLog.ps1
  |               |         +-- MinIO: scripts/Export-RunnerLogs.ps1
  |               |         +-- MinIO: scripts/Write-GoldenVersion.ps1
  |               +-- 3.10 Deploy monitor-hosts.json (generated from Config)
  |               +-- 3.11 Register 12 scheduled tasks
  |               +-- 3.12 Deploy tools
  |               |         +-- MinIO: tools/winrar-x64-701.exe            -> C:\Tools\
  |               |         +-- MinIO: tools/nssm-2.24.zip                 -> C:\Tools\
  |               |         +-- MinIO: tools/sysinternals/procexp64.exe    -> C:\Tools\SysInternals\
  |               |         +-- MinIO: tools/sysinternals/Procmon64.exe    -> C:\Tools\SysInternals\
  |               |         +-- MinIO: tools/sysinternals/handle64.exe     -> C:\Tools\SysInternals\
  |               |         +-- MinIO: tools/sysinternals/PSTools.zip      -> C:\Tools\SysInternals\
  |               |         +-- MinIO: tools/opencode/opencode-desktop-windows-x64-setup.exe
  |               |         +-- MinIO: tools/opencode/opencode.jsonc
  |               +-- 3.13 Final validation (17 checks)
  |               |         +-- Invoke-FinalValidation.ps1
  |               +-- 3.14 Write golden image version stamp
  |               |
  |               +-- DONE (no reboot)
  v
 Runner VM is operational
```

---

## Module Dependency Map

```
Bootstrap-GitLabRunner.ps1 (orchestrator -- the ONLY file Be1 fetches)
    |
    |-- [Embedded] TLS bypass, S3 client, bootstrap logging
    |-- [Embedded] Phase 0: downloads 6 files from MinIO
    |
    +-- lib/Config.ps1          <- loaded first (no dependencies)
    +-- lib/Common.ps1          <- depends on Config.ps1 ($Script:Config)
    |       |
    |       +-- Write-Log, Write-LogError, Write-LogWarn
    |       +-- Get-S3Object (AWS SigV4)
    |       +-- Install-S3Binary, Install-S3Archive, Test-PEBinary
    |       +-- Wait-ServiceRunning, Get-DnsServer
    |       +-- Set-PhaseMarker, Test-PhaseComplete
    |       +-- Invoke-Be1Reboot
    |
    +-- phases/Phase1-SystemPrep.ps1      <- uses Common.ps1 functions
    +-- phases/Phase2-DockerInstall.ps1   <- uses Common.ps1 functions
    +-- phases/Phase3-RunnerSetup.ps1     <- uses Common.ps1 + calls Invoke-FinalValidation
    |
    +-- validation/Invoke-FinalValidation.ps1  <- uses Common.ps1 + Config.ps1
```

All files are dot-sourced into the same scope by the orchestrator. They share `$Script:Config` and all functions from `Common.ps1`.

---

## Phase Detection (Marker Files)

The orchestrator is re-run from the top after each reboot. Marker files determine where to resume:

| Marker | Location | Meaning |
|--------|----------|---------|
| No markers | -- | Fresh start: run Phase 1 |
| `.phase1_complete` | `C:\GitLab-Runner\` | Phase 1 done: start Phase 2 |
| `.phase2_complete` | `C:\GitLab-Runner\` | Phase 2 done: start Phase 3 |

Markers older than 60 minutes are treated as stale and the phase is re-run.

---

## External Dependencies per Phase

| Phase | Source | Protocol | What |
|-------|--------|----------|------|
| 0 | MinIO | HTTPS + AWS SigV4 | 6 bootstrap scripts (lib, phases, validation) |
| 1 | MinIO | HTTPS + AWS SigV4 | Test-Dependencies.ps1, Import-Certificates.ps1, Enable-RemotePowerShell.ps1, kayhut-ca.crt |
| 2 | MinIO | HTTPS + AWS SigV4 | docker.exe, dockerd.exe |
| 3 | MinIO | HTTPS + AWS SigV4 | gitlab-runner.exe, MinGit.zip, 12 scripts, 8 tools |
| 3 | Harbor | Docker pull (insecure) | 3 container images (helper, servercore, windows) |
| 3 | GitLab | HTTPS | Runner registration (if PAT/legacy token) |

---

## Validation Scripts

| Script | When | Purpose |
|--------|------|---------|
| `Test-Dependencies.ps1` | Before install (Phase 1, step 1.0) | Pre-flight: DNS, S3 reachability, Harbor API |
| `Invoke-FinalValidation.ps1` | After install (Phase 3, step 3.13) | Post-flight: 17 checks on OS, Docker, Runner, Git, Defender, tasks, disk |

---

## Validation Checks (`Invoke-FinalValidation.ps1`)

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

---

## Artifact Sources

| Artifact Type | Source | Protocol |
|---------------|--------|----------|
| Bootstrap scripts (lib, phases, validation) | MinIO (`bootstrap/` prefix) | HTTPS + AWS Sig V4 |
| Runner binary, Docker binaries, MinGit | MinIO (`binaries/` prefix) | HTTPS + AWS Sig V4 |
| Maintenance scripts (12 files) | MinIO (`scripts/` prefix) | HTTPS + AWS Sig V4 |
| Tools (WinRAR, NSSM, SysInternals, OpenCode) | MinIO (`tools/` prefix) | HTTPS + AWS Sig V4 |
| CA certificate | MinIO (`certs/` prefix) | HTTPS + AWS Sig V4 |
| Container images (base, helper) | Harbor (`golden-image` project) | Docker pull (insecure registry) |
| Runner token | Be1 (injected as `GITLAB_RUNNER_TOKEN` env var) | -- |

---

## Troubleshooting by Module

When something fails, the install log (`C:\GitLab-Runner\logs\install.log`) shows the step number:

| Log shows | File to check |
|-----------|--------------|
| Bootstrap download failures | `Bootstrap-GitLabRunner.ps1` (Phase 0, embedded S3 client) |
| `[ERROR]` during 1.x steps | `phases/Phase1-SystemPrep.ps1` |
| `[ERROR]` during 2.x steps | `phases/Phase2-DockerInstall.ps1` |
| `[ERROR]` during 3.x steps | `phases/Phase3-RunnerSetup.ps1` |
| `[FAIL]` in validation | `validation/Invoke-FinalValidation.ps1` |
| S3 download failures | `lib/Common.ps1` -> `Get-S3Object` |
| Config values wrong | `lib/Config.ps1` |
| Phase stuck / re-running | Check marker files in `C:\GitLab-Runner\` |
