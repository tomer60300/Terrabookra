# Infrastructure Dependencies

Everything the golden image needs lives in two places: **MinIO S3** (files) and **Harbor** (container images).
This document is the single source of truth for what must be uploaded before provisioning a VM.

---

## MinIO S3 — Bucket: `gitlab-runner-golden`

Endpoint: `https://kayhut-minio.com:9000`

### Bucket Layout

```
gitlab-runner-golden/
│
├── binaries/
│   ├── docker/
│   │   ├── docker.exe              # Docker CLI 25.0.15
│   │   └── dockerd.exe             # Docker daemon 25.0.15 (~123 MB)
│   ├── git/
│   │   └── MinGit-2.43.0-64-bit.zip
│   └── gitlab-runner-16.7.0-windows-amd64.exe
│
├── certs/
│   └── kayhut-ca.crt               # Self-signed CA certificate
│
├── scripts/
│   ├── health-check.ps1            # Docker/Runner/disk/stale-container health
│   ├── disk-monitor.ps1            # Emergency prune at <10 GB
│   ├── docker-watchdog.ps1         # Restart Docker+Runner if daemon dies
│   ├── kill-stale-containers.ps1   # Kill CI containers stuck >4 hours
│   ├── Register-ScheduledTasks.ps1 # Creates all 12 scheduled tasks
│   ├── Import-Certificates.ps1     # Fetch cert from S3 + import to Trusted Root
│   ├── Enable-RemotePowerShell.ps1 # WinRM setup for remote PS
│   ├── Test-NetworkConnectivity.ps1# TCP probe logger (daily CSV)
│   ├── Write-JobLog.ps1            # CI job start/end wrapper logger
│   ├── Export-RdpAuditLog.ps1      # RDP session event parser
│   ├── Export-RunnerLogs.ps1       # Log collector — bundles all logs into zip
│   └── Write-GoldenVersion.ps1     # Golden image version stamp writer
│
└── tools/
    ├── winrar-x64-701.exe          # WinRAR silent installer
    ├── nssm-2.24.zip               # NSSM (Non-Sucking Service Manager)
    ├── opencode/
    │   ├── opencode-desktop-windows-x64-setup.exe
    │   └── opencode.jsonc           # Air-gapped config template
    └── sysinternals/
        ├── procexp64.exe            # Process Explorer
        ├── Procmon64.exe            # Process Monitor
        ├── handle64.exe             # Handle viewer
        └── PSTools.zip              # PsExec, PsList, etc.
```

### S3 Key Reference (Config.ps1 → actual S3 path)

| Config Key | S3 Object Key | Deployed To |
|---|---|---|
| `S3Keys.RunnerBin` | `binaries/gitlab-runner-16.7.0-windows-amd64.exe` | `C:\GitLab-Runner\gitlab-runner.exe` |
| `S3Keys.DockerExe` | `binaries/docker/docker.exe` | `C:\Program Files\Docker\docker.exe` |
| `S3Keys.DockerdExe` | `binaries/docker/dockerd.exe` | `C:\Program Files\Docker\dockerd.exe` |
| `S3Keys.MinGitZip` | `binaries/git/MinGit-2.43.0-64-bit.zip` | `C:\GitLab-Runner\git\` (extracted) |
| `S3Keys.WinRarExe` | `tools/winrar-x64-701.exe` | Silent install → `C:\Program Files\WinRAR\` |
| `S3Keys.NssmZip` | `tools/nssm-2.24.zip` | `C:\Tools\nssm.exe` (extracted) |
| `S3Keys.ProcExp` | `tools/sysinternals/procexp64.exe` | `C:\Tools\SysInternals\procexp64.exe` |
| `S3Keys.ProcMon` | `tools/sysinternals/Procmon64.exe` | `C:\Tools\SysInternals\Procmon64.exe` |
| `S3Keys.Handle` | `tools/sysinternals/handle64.exe` | `C:\Tools\SysInternals\handle64.exe` |
| `S3Keys.PsToolsZip` | `tools/sysinternals/PSTools.zip` | `C:\Tools\SysInternals\` (extracted) |
| `S3Keys.HealthCheck` | `scripts/health-check.ps1` | `C:\GitLab-Runner\scripts\health-check.ps1` |
| `S3Keys.DiskMonitor` | `scripts/disk-monitor.ps1` | `C:\GitLab-Runner\scripts\disk-monitor.ps1` |
| `S3Keys.DockerWdog` | `scripts/docker-watchdog.ps1` | `C:\GitLab-Runner\scripts\docker-watchdog.ps1` |
| `S3Keys.KillStale` | `scripts/kill-stale-containers.ps1` | `C:\GitLab-Runner\scripts\kill-stale-containers.ps1` |
| `S3Keys.RegTasks` | `scripts/Register-ScheduledTasks.ps1` | `C:\GitLab-Runner\scripts\Register-ScheduledTasks.ps1` |
| `S3KeysExtra.ImportCerts` | `scripts/Import-Certificates.ps1` | `C:\GitLab-Runner\scripts\Import-Certificates.ps1` |
| `S3KeysExtra.EnableRemotePS` | `scripts/Enable-RemotePowerShell.ps1` | `C:\GitLab-Runner\scripts\Enable-RemotePowerShell.ps1` |
| `S3KeysExtra.NetMonitor` | `scripts/Test-NetworkConnectivity.ps1` | `C:\GitLab-Runner\scripts\Test-NetworkConnectivity.ps1` |
| `S3KeysExtra.JobLog` | `scripts/Write-JobLog.ps1` | `C:\GitLab-Runner\scripts\Write-JobLog.ps1` |
| `S3KeysExtra.RdpAudit` | `scripts/Export-RdpAuditLog.ps1` | `C:\GitLab-Runner\scripts\Export-RdpAuditLog.ps1` |
| `S3KeysExtra.LogCollector` | `scripts/Export-RunnerLogs.ps1` | `C:\GitLab-Runner\scripts\Export-RunnerLogs.ps1` |
| `S3KeysExtra.GoldenVersion` | `scripts/Write-GoldenVersion.ps1` | `C:\GitLab-Runner\scripts\Write-GoldenVersion.ps1` |
| `S3KeysExtra.OpenCodeExe` | `tools/opencode/opencode-desktop-windows-x64-setup.exe` | `C:\Tools\` (installer) |
| `S3KeysExtra.OpenCodeConfig` | `tools/opencode/opencode.jsonc` | `%USERPROFILE%\.config\opencode.jsonc` |
| `S3Certs[0]` | `certs/kayhut-ca.crt` | `C:\GitLab-Runner\certs\kayhut-ca.crt` → Cert:\LocalMachine\Root |

**Total S3 objects: 25** (15 original + 9 new scripts + 2 OpenCode + 1 certificate - 2 shared with original)

---

## Environment Variables (Required Before Provisioning)

| Variable | Required | How to Set | Description |
|---|---|---|---|
| `GITLAB_RUNNER_TOKEN` | **Yes** | Be1/Aria VM property or Machine env var | Runner token — see below |

### GITLAB_RUNNER_TOKEN — Two Formats Supported

**Option 1: Runner Authentication Token (recommended for GitLab 16.0+)**

Starts with `glrt-`. Created in GitLab UI: Settings → CI/CD → Runners → New runner.
This token is already authenticated — the script writes it directly to config.toml
and **skips** the `gitlab-runner register` command.

```
GITLAB_RUNNER_TOKEN=glrt-AbCdEf123456
```

**Option 2: Registration Token or Personal Access Token (legacy)**

Does NOT start with `glrt-`. The script runs `gitlab-runner register --registration-token`
to exchange it for an auth token, then extracts the resulting `glrt-` token from the
generated config.toml.

```
GITLAB_RUNNER_TOKEN=GR1348941_xxxxxxxxxxxxxxxx
```

**How to provide via Be1/Aria:**

Set as a VM custom property that Be1 injects as a Machine-level environment variable
before the post-install script runs. The script checks `$env:GITLAB_RUNNER_TOKEN` first,
then falls back to `[System.Environment]::GetEnvironmentVariable('GITLAB_RUNNER_TOKEN', 'Machine')`.

---

## Harbor — Project: `golden-image`

Registry: `harbor.kayhut.com`

### Required Images

| Image | Tag | Used By |
|---|---|---|
| `harbor.kayhut.com/golden-image/gitlab-runner-helper` | `x86_64-v16.7.0-servercore1809` | Runner helper (must match runner version) |
| `harbor.kayhut.com/golden-image/servercore` | `ltsc2019` | Default CI job image in config.toml |
| `harbor.kayhut.com/golden-image/windows` | `ltsc2019` | Available base image for CI jobs |

### How They Get There

These are Windows container images that must be pulled from Docker Hub (or Microsoft MCR) on an internet-connected machine and pushed to Harbor:

```powershell
# On internet PC:
docker pull mcr.microsoft.com/windows/servercore:ltsc2019
docker tag mcr.microsoft.com/windows/servercore:ltsc2019 harbor.kayhut.com/golden-image/servercore:ltsc2019
docker push harbor.kayhut.com/golden-image/servercore:ltsc2019

docker pull mcr.microsoft.com/windows:ltsc2019
docker tag mcr.microsoft.com/windows:ltsc2019 harbor.kayhut.com/golden-image/windows:ltsc2019
docker push harbor.kayhut.com/golden-image/windows:ltsc2019

# Helper image — from GitLab registry:
docker pull registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:x86_64-v16.7.0-servercore1809
docker tag registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:x86_64-v16.7.0-servercore1809 harbor.kayhut.com/golden-image/gitlab-runner-helper:x86_64-v16.7.0-servercore1809
docker push harbor.kayhut.com/golden-image/gitlab-runner-helper:x86_64-v16.7.0-servercore1809
```

---

## VM Disk Layout (Expected by Scripts)

```
C: (100 GB) — OS drive
├── GitLab-Runner\
│   ├── gitlab-runner.exe
│   ├── config.toml
│   ├── certs\                   ← certificates fetched from S3
│   ├── git\cmd\git.exe          ← MinGit extracted
│   ├── scripts\                 ← all 10 maintenance/feature scripts
│   ├── logs\
│   │   ├── install.log          ← main install log
│   │   ├── jobs\                ← CI job start/end logs (daily)
│   │   ├── network\             ← TCP probe CSVs (daily)
│   │   └── rdp\                 ← RDP session logs (daily)
│   ├── .phase1_complete         ← phase marker
│   └── .phase2_complete         ← phase marker
├── Program Files\Docker\
│   ├── docker.exe
│   └── dockerd.exe
├── ProgramData\docker\config\
│   └── daemon.json
└── Tools\
    ├── nssm.exe
    ├── SysInternals\
    └── (WinRAR installed to Program Files)

E: (1 TB) — Data drive (preferred, C: fallback)
├── GitLab-Runner\
│   ├── builds\                  ← CI job workspaces
│   └── cache\                   ← CI cache
├── docker-data\                 ← Docker data-root
└── pagefile.sys                 ← custom pagefile
```

---

## Download Checklist (Internet PC → Air-Gap Transfer)

Use this when preparing files on the internet-connected machine before uploading to MinIO/Harbor.

### Binaries

- [ ] `docker.exe` 25.0.15 — https://download.docker.com/win/static/stable/x86_64/
- [ ] `dockerd.exe` 25.0.15 — same archive as above
- [ ] `gitlab-runner-windows-amd64.exe` 16.7.0 — https://gitlab-runner-downloads.s3.amazonaws.com/v16.7.0/binaries/gitlab-runner-windows-amd64.exe
- [ ] `MinGit-2.43.0-64-bit.zip` — https://github.com/git-for-windows/git/releases

### Certificates

- [ ] `kayhut-ca.crt` — your self-signed CA .crt file

### Tools

- [ ] `winrar-x64-701.exe` — https://www.rarlab.com/download.htm
- [ ] `nssm-2.24.zip` — https://nssm.cc/download
- [ ] `procexp64.exe` — https://learn.microsoft.com/sysinternals/downloads/process-explorer
- [ ] `Procmon64.exe` — https://learn.microsoft.com/sysinternals/downloads/process-monitor
- [ ] `handle64.exe` — https://learn.microsoft.com/sysinternals/downloads/handle
- [ ] `PSTools.zip` — https://learn.microsoft.com/sysinternals/downloads/pstools
- [ ] `opencode-desktop-windows-x64-setup.exe` — https://opencode.ai (or internal source)

### Container Images (push to Harbor)

- [ ] `mcr.microsoft.com/windows/servercore:ltsc2019`
- [ ] `mcr.microsoft.com/windows:ltsc2019`
- [ ] `registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:x86_64-v16.7.0-servercore1809`

---

## Version Compatibility Matrix

| Component | Version | Constraint |
|---|---|---|
| Windows Server | 2019 LTSC (Build 17763) | Must match container base image tag `ltsc2019` |
| Docker | 25.0.15 | Raw binaries, process isolation, no Mirantis |
| GitLab Runner | 16.7.0 | Must match helper image tag `v16.7.0` |
| GitLab Server | 16.7.10-ee | Runner version must be ≤ server version |
| Helper Image | v16.7.0-servercore1809 | `1809` = Build 17763 = Server 2019 |
| MinGit | 2.43.0 | Any 2.x works, this is tested |
