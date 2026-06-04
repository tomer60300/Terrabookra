# Terrabookra — Environment-Assumption Review

**Lens:** what the flow *consumes* but does not itself *create or verify* → the things
that break on an unknown VM. Reviewed against the 2.4.6 baseline.

## TL;DR

The flow is actually disciplined about most of its own setup. The real risks are
preconditions that fail **late and cryptically** instead of **early and clearly**, plus a
few host facts that are assumed rather than checked.

**Fix shipped:** `Assert-Environment.ps1` — a fail-fast preflight that asserts every
precondition below and aborts with a clear message before any work begins. Wire it in as
the first step (see *How to wire in*). Plus targeted patches P1–P5.

## Dependency map (consumed → does the flow guarantee it?)

| Precondition | Consumed by | Guaranteed by flow? | Status |
|---|---|---|---|
| `docker`/`git` on **machine PATH** | every cleanup task, watchdogs, disk-monitor, validation | **YES** — Phase1 §1.6 adds DockerDir, git\cmd, Tools, Runner | OK (minor substring bug → P2) |
| Event-log source `GitLabRunner` | disk-monitor, watchdogs, health-check, validation, certs | **YES** — Phase1 §1.1 `New-EventLog` | OK in-flow; standalone gap → G4/P3 |
| Core dirs (Runner/Logs/Scripts/Git/Tools/data-root) | phases + scripts | **YES** — Phase1 §1.7, Phase2, Phase3 §3.9 | OK |
| `docker-users` local group | dockerd service | **YES** — Phase2 §2.1 | OK |
| `GITLAB_RUNNER_TOKEN` | Phase3 registration | **hard-checked** Phase3 (FATAL if absent) | OK — good pattern |
| **MinIO credentials** | Phase 0 bootstrap + *every* download | **NO** — `YOUR_ACCESS_KEY_HERE` placeholders in Config **and** Bootstrap | **GAP G1 (HIGH)** |
| **OS edition / build / PS version** | feature install, version-pinned tools/images | only at **final** validation (line 68) | **GAP G2 (MED)** |
| **Data drive = fixed NTFS** | docker `data-root` | NTFS checked in Phase2; "fixed" (not DVD/USB) is **not** | **GAP G5 (MED)** |
| MinIO/Harbor/GitLab name resolution | downloads, pulls | `Test-Dependencies` (DNS/S3/Harbor) — *if it runs* | OK-ish (can be bypassed → H3 in REVIEW.md) |
| Harbor auth | image pulls | assumed **anonymous** (creds empty) | GAP — see M6 in REVIEW.md |

## Gaps & fixes

### G1 — Placeholder MinIO credentials are never detected (HIGH)
`lib/Config.ps1:46-47` and `Bootstrap-GitLabRunner.ps1:49-50` ship `YOUR_ACCESS_KEY_HERE` /
`YOUR_SECRET_KEY_HERE`. Nothing checks them, so a forgotten substitution produces 403s deep
in Phase 0 with no hint of the real cause.
**Fix:** `Assert-Environment.ps1` hard-fails on placeholder/empty creds at the Config level.
Phase 0 runs *before* Config is downloaded, so Bootstrap needs its own inline guard → **P1**.

### G2 — No early OS / edition / PowerShell guard (MED)
A non-Server-2019 host (wrong build, workstation SKU, or PS ≠ 5.1) runs the entire flow and
only trips `OS Build = 17763` at *final* validation — after installing version-pinned tools
and images that may not match.
**Fix:** `Assert-Environment.ps1` checks build (WARN, `-Strict` to fail), Server SKU, and
PS ≥ 5 (HARD) up front. Run it first.

### G5 — Data-drive auto-detect can latch onto a removable volume (MED)
`Config.ps1:21` / `disk-monitor.ps1` pick `E:` whenever `Test-Path 'E:\'` is true. On an
unknown VM `E:` could be a DVD or USB. Phase2 rejects non-NTFS, but an NTFS-formatted USB
would silently become the Docker `data-root`.
**Fix:** `Assert-Environment.ps1` requires the data drive to be **Fixed + NTFS**. Optionally
also harden the Config auto-detect (only pick `E:` if `(Get-Volume E).DriveType -eq 'Fixed'`).

### G4 — Standalone scripts assume the event-log source exists (MED)
The maintenance scripts call `Write-EventLog -Source 'GitLabRunner'`, which throws if the
source is unregistered. In-flow it's created by Phase1 §1.1, so scheduled tasks are fine —
but a script run on a host where Phase 1 never completed will throw.
**Fix:** `Assert-Environment.ps1` creates the source if missing. For belt-and-suspenders, add
the guard **P3** to each script that writes events.

### G6 — PATH-add uses a substring test (LOW)
`Phase1:111` `if ($currentPath -notlike "*$p*")`. `C:\Tools` won't be added if
`C:\Tools\SysInternals` is already present (substring match), and vice-versa.
**Fix:** **P2** — compare exact `;`-split segments.

## How to wire in `Assert-Environment.ps1`

1. Stage it like the other scripts: add an `S3KeysExtra` entry and deploy it in Phase 3 §3.9
   (or fetch it in Phase 0 alongside Config/Common).
2. Call it **first** — either in Bootstrap Phase 0 right after Config + Common are dot-sourced,
   or at the very top of `Invoke-Phase1` before §1.0:
   ```powershell
   & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$($Script:Config.ScriptsDir)\Assert-Environment.ps1"
   if ($LASTEXITCODE -ne 0) { Write-LogError 'FATAL: environment preflight failed'; exit 1 }
   ```
3. On locked-down production, add `-Strict` to treat warnings (OS-build drift, unreachable
   MinIO) as hard stops.

## Patches (copy-paste)

**P1 — Bootstrap placeholder guard** (`Bootstrap-GitLabRunner.ps1`, in MAIN after the cred vars; ⚠VERIFY against 2.4.7i):
```powershell
if ([string]::IsNullOrWhiteSpace($Script:BootstrapAccessKey) -or $Script:BootstrapAccessKey -like 'YOUR_*') {
    Write-BootstrapLog 'FATAL: MinIO credentials not set in Bootstrap-GitLabRunner.ps1 (still placeholder).'
    exit 1
}
```

**P2 — Phase1 PATH exact-segment add** (`Phase1-SystemPrep.ps1:110-112`; ⚠VERIFY):
```powershell
$segs = $currentPath -split ';'
foreach ($p in @($Script:Config.DockerDir, (Join-Path $Script:Config.GitDir 'cmd'), $Script:Config.ToolsDir, $Script:Config.RunnerDir)) {
    if ($segs -notcontains $p) { $currentPath = "$currentPath;$p"; $segs += $p }
}
```

**P3 — event-source defensive guard** (top of disk-monitor / docker-watchdog / health-check / kill-stale-containers / Import-Certificates):
```powershell
if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
    try { New-EventLog -LogName Application -Source $source } catch {}
}
```

**P4 — data-drive must be fixed** (`lib/Config.ps1:21`):
```powershell
$Script:DataDrive = if ((Test-Path 'E:\') -and ((Get-Volume -DriveLetter E -EA SilentlyContinue).DriveType -eq 'Fixed')) { 'E:' } else { 'C:' }
```

**P5 — early OS guard** (only if you don't run `Assert-Environment.ps1`; top of `Invoke-Phase1`):
```powershell
if ([int][Environment]::OSVersion.Version.Build -ne 17763) {
    Write-LogWarn "OS build $([Environment]::OSVersion.Version.Build) != 17763 (Server 2019 LTSC) -- artifacts are pinned; aborting"; exit 1
}
```

## Already safe (verified — no action)

Machine PATH for `docker`/`git` (Phase1 §1.6); all core directory creation; `docker-users`
group (Phase2); the runner-token FATAL gate (Phase3); event-log source in the normal in-flow
order. These are configured by the flow and need no change.
