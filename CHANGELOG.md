# Changelog

All notable changes to the Terrabookra project are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)

---

## [2.3.1] -- 2026-04-19

### Fixed -- 9 issues from external code review

1. **CRITICAL: UTF-8 BOM + non-ASCII chars** -- All 22 .ps1 files now have UTF-8
   BOM. Em dashes, arrows, and box-drawing chars replaced with ASCII equivalents.
   PS 5.1 reads BOM-less UTF-8 as ANSI; byte 0x94 (em dash middle byte) maps to
   `"` in Windows-1252, causing string parse failures.

2. **CRITICAL: `exit` in Test-Dependencies.ps1 kills Phase 1** -- Phase 1 called
   the validator with `& $depScript` (in-process). `exit` terminated the entire
   installer. Now calls via `powershell.exe -File` subprocess.

3. **HIGH: Failed runner registration continues with bad token** -- When
   registration fails for PAT/legacy tokens, the PAT was written as the runner
   auth token in config.toml (won't work). Now logs explicit error and sets
   `$Script:RunnerRegistrationFailed` flag for degraded status.

4. **HIGH: Runner service install missing --config/--working-directory** --
   `gitlab-runner install` without explicit paths depends on CWD, which is
   unpredictable in Be1 post-install. Now passes `--working-directory` and
   `--config` explicitly.

5. **HIGH: docker-users group not created** -- Raw binary Docker install doesn't
   create the `docker-users` group (MSI does). daemon.json references it.
   Phase 2 now creates the group before writing daemon.json.

6. **MEDIUM: Runner service failure continues to OPERATIONAL** -- Phase 3 now
   tracks `$Script:RunnerRegistrationFailed` and reports DEGRADED status if
   registration or service start failed.

7. **MEDIUM: S3 download failures silently ignored** -- Maintenance script
   downloads in Phase 3 step 3.9 now have try/catch + file existence check.
   Failures counted and logged as warning.

8. **MEDIUM: Disk monitor only checks C:** -- `disk-monitor.ps1` and
   `health-check.ps1` now auto-detect and check the data drive (E: if present)
   in addition to C:. New `-DataDrive` parameter. `Invoke-FinalValidation.ps1`
   also checks data drive free space.

9. **MEDIUM: Stale container regex misses days/weeks** -- `kill-stale-containers.ps1`
   and `health-check.ps1` now parse weeks, days, and hours from Docker's
   `RunningFor` field. Previously only matched `(\d+)\s+hours`.

---

## [2.3.0] -- 2026-04-19

### Changed -- No hardcoded URLs/hostnames outside Config

1. **Config.ps1 -- DRY refactor** -- All hostnames/URLs extracted into base variables
   at the top of the file. `PrePullImages`, `HelperImage`, `InsecureRegistries`,
   and `MonitorHosts` are now derived from base variables -- change a hostname once,
   it propagates everywhere.
   - New base variables: `$_harborHost`, `$_gitLabHost`, `$_minioHost`, `$_artifactoryHost`, `$_be1Host`
   - New config keys: `HarborProject`, `GitLabRegistry`, `ArtifactoryHost`, `Be1Host`
   - Derived values built after the hashtable (single source of truth)

2. **Test-NetworkConnectivity.ps1** -- No longer has hardcoded host list.
   Reads from `monitor-hosts.json` (deployed by Phase 3 from `Config.MonitorHosts`).
   Falls back to `-Hosts` parameter.

3. **Register-ScheduledTasks.ps1** -- Paths now parameterized (`-ScriptsDir`,
   `-LogsDir`, `-BuildsDir`). Phase 3 passes Config values.

4. **Phase3-RunnerSetup.ps1** -- All hardcoded paths replaced with Config keys:
   - Defender exclusions use `$Config.RunnerDir`, `$Config.DockerDir`, etc.
   - config.toml `pre_build_script`/`post_build_script` use `$Config.ScriptsDir`
   - Inline fallback tasks use `$Config.LogsDir`, `$Config.BuildsDir`
   - New step 3.10: deploys `monitor-hosts.json` from `Config.MonitorHosts`
   - Steps renumbered: 3.10->3.14 (was 3.10->3.13)

5. **Standalone scripts parameterized** -- All maintenance scripts accept
   key paths as parameters with sensible defaults:
   - `health-check.ps1` -- `-LogFile`
   - `disk-monitor.ps1` -- `-LogFile`
   - `docker-watchdog.ps1` -- `-LogFile`
   - `kill-stale-containers.ps1` -- `-MaxAgeHours`, `-LogFile`
   - `Write-GoldenVersion.ps1` -- `-RunnerBin`, `-GitExe`, `-CertsDir`
   - `Export-RunnerLogs.ps1` -- `-RunnerDir`, `-DaemonJson`
   - `Get-FleetHealth.ps1` -- `-RunnerDir` (passed to remote scriptblock)

6. **Golden image version** bumped to `2.3.0`

7. **New: `validation/Test-Dependencies.ps1`** -- Pre-flight dependency validator
   - Resolves all hostnames from `Config.MonitorHosts` via DNS
   - HEAD request (AWS SigV4) on all 26 MinIO S3 objects -- no download
   - Registry API v2 manifest HEAD for all 3 Harbor pre-pull images -- no pull
   - Runs standalone or integrated from Phase 1 step 1.0
   - Color-coded output with PASS/FAIL per check, summary with failed items
   - Event Log entries: 9030 (all pass) / 9031 (failures)
   - New S3 key: `S3KeysExtra.DepValidator`

8. **Phase 1** -- New step 1.0 runs dependency validation as pre-flight check.
   PATH additions now use Config keys instead of hardcoded paths.

9. **Invoke-FinalValidation.ps1** -- Defender exclusion check uses `$Config.RunnerDir`

### Fixed -- 6 bugs found in deep audit

1. **CRITICAL: `Write-JobLog.ps1` -- PS 5.1 parse error** -- All 7 env-var
   assignments used `??` null-coalescing operator (PS 7.1+ only). Causes
   immediate parse error on Server 2019. Rewritten to `if/else`. Also added
   `-LogDir` and `-MaxAgeDays` parameters (missed in parameterization sweep).

2. **`Export-RdpAuditLog.ps1` -- missing parameters** -- Missed in parameterization
   sweep. Added `-LogDir` and `-MaxAgeDays` parameters.

3. **`Invoke-FinalValidation.ps1` -- task count check missed 2 tasks** -- Regex
   `'^(Docker|Runner|Disk|Log)-'` didn't match `Network-Connectivity-Monitor`
   or `RDP-Audit-Logger`. Fixed to `'^(Docker|Runner|Disk|Log|Network|RDP)-'`
   with threshold `>=10` (was `>=8`).

4. **`Phase3-RunnerSetup.ps1` -- ConvertTo-Json array unwrapping** -- Pipeline
   `$Config.MonitorHosts | ConvertTo-Json` unwraps single-element arrays in
   PS 5.1 (produces JSON object instead of array). Fixed with
   `ConvertTo-Json -InputObject @($Config.MonitorHosts) -Depth 2`.

5. **`Phase3-RunnerSetup.ps1` -- missing -OutputPath** -- `Write-GoldenVersion`
   call didn't pass `-OutputPath`, so version stamp always went to hardcoded
   default. Now passes `(Join-Path $Config.RunnerDir '.golden-version')`.

6. **`Test-Dependencies.ps1` -- event ID collision** -- Used 9020/9021 which
   collided with `Import-Certificates.ps1`. Changed to 9030/9031.

---

## [2.2.1] -- 2026-04-19

### Fixed -- 4 audit issues

1. **OpenCode never deployed** -- Phase 3 step 3.11 now downloads installer + config from S3
   - Installer saved to `C:\Tools\opencode-setup.exe` (manual install)
   - Config deployed to `%USERPROFILE%\.config\opencode.jsonc`

2. **Phase 1 scripts missing on fresh VM** -- Steps 1.10 and 1.11 now fetch
   `Import-Certificates.ps1` and `Enable-RemotePowerShell.ps1` from S3 before
   calling them. Previously they were silently skipped on first boot because
   Phase 3 (which deploys scripts) hadn't run yet.

3. **Inline scheduled task fallback incomplete** -- Added `Network-Connectivity-Monitor`
   and `RDP-Audit-Logger` to the inline fallback (was 10 tasks, now 12 -- matches
   `Register-ScheduledTasks.ps1`).

4. **Token handling** -- `GITLAB_RUNNER_TOKEN` now supports two formats:
   - `glrt-XXXX` (Runner Authentication Token, GitLab 16.0+) -- written directly
     to config.toml, registration skipped
   - Registration token / PAT -- runs `gitlab-runner register --registration-token`,
     extracts the resulting auth token from config.toml
   - Documented in `lib/Config.ps1` and `docs/DEPENDENCIES.md`
   - Hardcoded `harbor.kayhut.com/golden-image/servercore:ltsc2019` in config.toml
     and register command now uses `$Config.HarborUrl` variable

---

## [2.2.0] -- 2026-04-16

### Added -- 4 new features

1. **Runner log collector** (`scripts/Export-RunnerLogs.ps1`)
   - One-command bundler: install log, daily logs (jobs/network/rdp), maintenance logs,
     Docker diagnostics, Runner diagnostics, Event Log export, system info, golden version
   - Creates timestamped zip: `runner-logs-HOSTNAME-YYYYMMDD-HHmmss.zip`
   - Runnable locally or via PSRemoting from admin PC

2. **Golden image version stamp** (`scripts/Write-GoldenVersion.ps1`)
   - Writes `C:\GitLab-Runner\.golden-version` (JSON) at end of Phase 3 (step 3.13)
   - Contains: image version, build date, host, OS build, Runner/Docker/Git versions,
     component status (certs, WinRM, scheduled tasks count)
   - Query across fleet: `Invoke-Command -ComputerName runner01,runner02 -ScriptBlock { Get-Content C:\GitLab-Runner\.golden-version | ConvertFrom-Json }`

3. **Fleet health dashboard** (`fleet/Get-FleetHealth.ps1`)
   - Runs from admin PC, queries all runners via WinRM
   - Collects: hostname, status, uptime, disk, Docker/Runner status, containers, image version
   - Color-coded HEALTHY/DEGRADED/UNREACHABLE output
   - Optional CSV export with `-ExportCsv`

4. **Fleet command runner** (`fleet/Invoke-FleetCommand.ps1`)
   - Execute any PowerShell command across all runners in parallel
   - Supports `-Command` (inline) or `-ScriptFile` (file)
   - Grouped output by hostname, unreachable host reporting
   - Throttle limit for large fleets

### Changed
- `lib/Config.ps1` -- added `S3KeysExtra.LogCollector`, `S3KeysExtra.GoldenVersion`, `GoldenImageVersion`
- `phases/Phase3-RunnerSetup.ps1` -- deploys 2 new scripts in step 3.9, added step 3.13 (version stamp)
- S3 objects: 23 -> 25 (+2 new scripts)
- Phase 3 steps: 3.1–3.12 -> 3.1–3.13

---

## [2.1.1] -- 2026-04-16

### Fixed
- **Certificate import** -- certificates now fetched from MinIO S3 before importing
  - `Import-Certificates.ps1` downloads `.crt` files listed in `$Config.S3Certs` to `CertsDir` first
  - Then imports all found `.crt/.cer/.pem` into Trusted Root (same logic as before)
  - Added Event ID 9022 for S3 download failures
  - `lib/Config.ps1` -- added `S3Certs` array with S3 object keys for certificate files

---

## [2.1.0] -- 2026-04-16

### Added -- 6 new features

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
- `lib/Config.ps1` -- added CertsDir, JobLogDir, NetLogDir, RdpLogDir, MonitorHosts, S3KeysExtra
- `phases/Phase1-SystemPrep.ps1` -- added steps 1.10 (certs), 1.11 (WinRM), 1.12 (audit policy)
- `phases/Phase3-RunnerSetup.ps1` -- deploys new scripts, creates log subdirectories, job wrapper in config.toml
- `scripts/Register-ScheduledTasks.ps1` -- 10 -> 12 tasks (+ Network-Connectivity-Monitor, RDP-Audit-Logger)
- `config.toml` template -- added `pre_build_script` and `post_build_script` for job logging

---

## [2.0.0] -- 2026-04-16

### Changed
- **BREAKING: Modular refactor** -- `Bootstrap-GitLabRunner.ps1` is now a slim orchestrator (~80 lines)
  that dot-sources focused modules instead of containing all logic in one 823-line file
- Split into manager/worker pattern:
  - `lib/Config.ps1` -- all configuration in one place
  - `lib/Common.ps1` -- shared helpers (TLS, logging, S3, PE validation, phase markers, reboot)
  - `phases/Phase1-SystemPrep.ps1` -- system preparation
  - `phases/Phase2-DockerInstall.ps1` -- Docker installation
  - `phases/Phase3-RunnerSetup.ps1` -- runner setup, maintenance, tools
  - `validation/Invoke-FinalValidation.ps1` -- 17-check validation suite

### Added
- `lib/` directory for shared libraries
- `phases/` directory with one file per phase
- `validation/` directory for the validation suite
- Folder READMEs for `lib/`, `phases/`, `validation/`
- Module dependency map in ARCHITECTURE.md
- Troubleshooting-by-module guide in ARCHITECTURE.md

### Why
- Easier to debug on air-gapped VMs -- log step numbers point to exact files
- Each module has single responsibility and clear boundaries
- Configuration changes are isolated to `lib/Config.ps1`
- Phases can be tested independently

---

## [1.0.0] -- 2026-04-16

### Added
- Initial repository setup with full project structure
- `Bootstrap-GitLabRunner.ps1` -- three-phase post-install script for Be1 (VMware Aria)
  - Phase 1: System prep, services, env vars, Windows features (Containers + Hyper-V)
  - Phase 2: Docker 25.0.15 raw binary install, `daemon.json`, `dockerd` service registration
  - Phase 3: Runner install, registration, config.toml, image pre-pull, maintenance, 17-check validation
- Maintenance scripts with proper headers, logging, and event log integration:
  - `health-check.ps1` -- service and disk health monitoring
  - `docker-watchdog.ps1` -- auto-restart Docker if unresponsive
  - `disk-monitor.ps1` -- emergency prune on critically low disk
  - `kill-stale-containers.ps1` -- kill CI containers running > 4 hours
  - `Register-ScheduledTasks.ps1` -- creates all 10 scheduled tasks
- Binaries:
  - `gitlab-runner-16.7.0-windows-amd64.exe`
  - `docker.exe` + `dockerd.exe` (Docker 25.0.15)
  - `MinGit-2.43.0-64-bit.zip`
- Tools:
  - `winrar-x64-701.exe`, `nssm-2.24.zip`
  - SysInternals: `procexp64.exe`, `Procmon64.exe`, `handle64.exe`, `PSTools.zip`
- Documentation:
  - `README.md` -- project overview, structure, configuration
  - `docs/ARCHITECTURE.md` -- system architecture and phase details
  - `docs/INTERNET-PC-CHECKLIST.md` -- download list for USB transfer into air-gapped network
  - Folder READMEs for `scripts/`, `binaries/`, `tools/`

### Notes
- Docker Phase 2 uses raw zip binaries (docker.exe + dockerd.exe) -- NOT Mirantis installer
- All TLS validation bypassed (self-signed certs, air-gapped network)
- MinIO credentials are placeholder -- replace before deployment
