# Changelog

All notable changes to the Terrabookra project are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)

---

## [2.4.6] -- 2026-04-30

### Performance

- **Phase 3 image pulls now run in parallel as background jobs** and start
  immediately after Docker is verified ready (step 3.5), instead of running
  sequentially in the foreground after the rest of Phase 3 completes. The
  three pre-pull images (`servercore:ltsc2019`, `windows:ltsc2019`, and
  the `gitlab-runner-helper`) launch as concurrent `Start-Job` background
  processes; steps 3.6 through 3.14 (token resolution, runner registration,
  service install, scripts deploy, scheduled tasks, tools install, OpenCode,
  observability) all run in the foreground in parallel with the pulls.
  A new `Wait-Job` step right before final validation (3.14.5) collects
  the pull results and FATALs if any failed.

  Expected impact on cold provision time: total Phase 3 wall time
  approaches `max(longest_pull, sum_of_other_steps)` instead of
  `sum_of_pulls + sum_of_other_steps`. On a fresh VM where the
  `windows:ltsc2019` pull dominates at ~25 minutes and the rest of
  Phase 3 takes ~5-10 minutes, that's roughly a 30-50% reduction in
  total Phase 3 time.

### Fixed

- **`scripts/Import-Certificates.ps1` no longer re-downloads the cert
  from MinIO when it's already on disk.** The trust-store import was
  already idempotent (skipped on thumbprint match); now the S3 fetch
  is also skipped if the `.crt` file exists in `$CertsDir` with
  non-zero size. Saves one round-trip per cert per script invocation.
- **Phase 3 step 3.9 deploy loops skip re-fetching scripts that are
  already on disk.** `Import-Certificates.ps1` was being re-downloaded
  in step 3.9 even though Phase 1 step 1.10 had already deposited it
  during the cert-import flow. Same skip-if-exists pattern applied to
  both deploy loops; reports the count of skipped files in the log.

### Notes

- Pull jobs share the runner's `docker login` state because credentials
  persist to `%USERPROFILE%/.docker/config.json` -- one login in the
  parent process is inherited by all child processes.
- Windows containers' `windowsfilter` driver still serialises layer
  EXTRACTION across pulls (single-threaded against the data drive),
  so the speedup comes mostly from overlapping network downloads and
  from running pulls in parallel with the rest of Phase 3 work. It is
  not a 3x speedup, but consistently 30-50%.

---

## [2.4.5] -- 2026-04-30

### Fixed

- **`verify-minio` now implements Harbor's Bearer token-exchange flow.**
  Previously the manifest check sent HEAD/GET with at most a Basic auth
  header, which Harbor rejects with `401 Unauthorized` -- even for
  publicly-readable repos. Harbor's `WWW-Authenticate: Bearer realm=...`
  challenge is the same dance `docker pull` runs internally:
    1. HEAD/GET the manifest; receive 401 with the Bearer challenge
       header.
    2. Parse `realm`, `service`, `scope` out of the challenge.
    3. GET `<realm>?service=<service>&scope=<scope>` -- with optional
       Basic auth from `HarborUser`/`HarborPass`, or anonymously when
       both are empty (Harbor honours anonymous token requests for
       public projects).
    4. Receive `{"token": "..."}`. Retry the manifest with
       `Authorization: Bearer <token>`.
  The previous code's GET fallback on 401 still did the GET unauthenticated,
  which Harbor also rejected. Result: every Harbor row in verify-minio
  came back FAIL with HTTP 401 even though `docker pull` worked fine.
  Now the row reports e.g. `digest=sha256:abc... (Bearer auth)` and the
  gate goes green.

### Added

- `Get-HarborBearerToken` helper -- pure PowerShell, parses
  `WWW-Authenticate: Bearer realm="...",service="...",scope="..."` and
  GETs the token from the realm URL. Anonymous when no creds, Basic-
  authenticated against the realm when creds are set.
- `Send-HarborManifestProbe` helper -- consolidates HEAD/GET request
  logic so the probe sequence (anonymous -> Bearer challenge -> token
  exchange -> retry) reads as a clean state machine instead of nested
  try/catch.

---

## [2.4.4] -- 2026-04-30

### Fixed

- **`Test-Dependencies.ps1` FileMap loader bug.** Previously dereferenced
  `$Script:Config.PSScriptRoot` (which doesn't exist -- `Config` is a
  hashtable, not a script) and then called `Split-Path $null` and
  `Test-Path $null` on the result, raising two non-fatal exceptions per
  run. Replaced with a single `$repoRoot = Split-Path $PSScriptRoot -Parent`
  derivation that's always defined. Same fix applied to the
  `Substitute-Aliases.ps1` loader path.
- **`Test-Dependencies.ps1` was missing existence checks for files
  uploaded via `$FileMap` but not present in `$Config.S3Keys` /
  `S3KeysExtra` / `S3Certs`.** Notably, `Bootstrap-GitLabRunner.ps1` and
  `lib/Common.ps1` were never HEAD-checked. Now `$allS3Keys` is the union
  of all four sources, so every key the sync uploads gets verified.

### Added

- **Bootstrap routing via `BOOTSTRAP_S3_PATH` env var.** When set
  (format: `bucket/key/path`), `Sync-ToMinio.ps1` routes
  `Bootstrap-GitLabRunner.ps1` to that alternate bucket+key while every
  other file still goes to `MINIO_BUCKET`. Same endpoint, same
  credentials. Use case: Be1's MinIO read permissions don't extend to
  the main `gitlab-runner-golden` bucket -- park the bootstrap in a
  Be1-readable bucket without splitting credentials. When unset, falls
  back to the existing default location.
  - `Test-Dependencies.ps1` reads the same env var and checks the
    bootstrap in the alternate bucket too.
  - `Put-S3Object` got an optional `-BucketOverride` parameter; the
    main loop passes it for the bootstrap row only.
  - Sync output now shows the actual bucket each file went to:
    `UPLOADED: Bootstrap-GitLabRunner.ps1 -> be1-scripts/runners/...`.

---

## [2.4.3] -- 2026-04-30

### Fixed

- **Harbor manifest check now handles HTTP 401** in addition to 405 for the
  HEAD->GET fallback. Harbor returns 401 (not 405) for HEAD on manifest
  endpoints when no Authorization header is sent, even on anonymously-
  readable repos. `docker pull` works because it always uses GET internally;
  the verifier now matches that behaviour. Previously this was reported as a
  hard auth failure even for healthy registries.

### Changed

- **Soft-optional S3 keys** are now reported as `WARN`, not `FAIL`, when
  missing. The first (and currently only) soft-optional key is
  `tools/openssh/administrators_authorized_keys` -- runners with AD password
  auth alone work fine without it; only fleets that opt in to public-key
  auth need the file uploaded. Verify-minio gate exit code now considers
  only hard `FAIL` rows; warnings are surfaced in the summary but do not
  fail the pipeline.
- `Test-Dependencies.ps1` summary output reorganised into separate `Failed`
  and `Warnings (not failing the gate)` sections so the two are visually
  distinct in CI logs.

### Notes (no code change)

- All binary blobs under `tools/<binary>/` (WebView2 installer, OpenCode
  setup, OpenSSH zip, observability MSIs, the 14 tool installers, helper
  binaries under `binaries/`) are uploaded to MinIO **manually** via USB
  walk -- the CI sync only handles source code (`.ps1`, `.toml`, `.jsonc`).
  This is unchanged from 2.4.0; documenting here for clarity.

---

## [2.4.2] -- 2026-04-30

### Added

- **Alias auto-substitution at sync time** (`ci/Substitute-Aliases.ps1`).
  Internal GitLab CI can now provide real hostnames as masked CI variables
  and the sync pipeline rewrites file content in-flight, so MinIO ends up
  holding real internal FQDNs while the public repo continues to hold
  `kayhut.com` / `Terrabookra` aliases. Removes the need to maintain a
  separate de-aliased internal mirror of the source code.
  - **New CI variables (all optional):** `REAL_HARBOR_HOST`,
    `REAL_GITLAB_HOST`, `REAL_MINIO_HOST`, `REAL_BE1_HOST`,
    `REAL_PROJECT_NAME`.
  - When set, every text file uploaded to MinIO has its aliases replaced
    (binary files / NUL-containing content are passed through unchanged).
  - When unset, files upload verbatim. Public-side users see no change.
- **`verify-minio` is substitution-aware.** `Test-Dependencies.ps1` sources
  the same `Substitute-Aliases.ps1` helper and applies it to local bytes
  before computing the MD5 used in the ETag content-match check. The
  result: MD5(local-substituted) == ETag(remote-substituted), so the
  content-match gate still passes when substitution is active.
  - On a runner (where `ci/` isn't deployed), `Convert-Aliases` falls back
    to a passthrough stub so the script still works for pre-flight checks.

### Why

The previous setup required two repos: a public one with aliases and an
internal mirror with real hostnames hardcoded in source. Keeping them in
sync was error-prone, especially after the 2.4.0 refactor that touched
many files. This change makes the public repo the single source of truth;
the internal CI's job is to inject real values from environment variables
at upload time.

---

## [2.4.1] -- 2026-04-30

### Added

- **`verify-minio` content-match upgrade** -- `validation/Test-Dependencies.ps1`
  now compares the **MD5 of every local repo file** to the **ETag returned by
  MinIO** for the matching S3 object. S3/MinIO ETag for single-PUT uploads
  (which `Sync-ToMinio.ps1` always uses) IS the MD5 of the content, so this
  catches both missing keys *and* stale/corrupt blobs at the right key. No
  extra round-trips beyond the existing HEAD; ~1 ms of MD5 compute per file.
- **`ci/FileMap.ps1`** -- shared single source of truth for the
  `repo-path -> S3-key` mapping. Both `ci/Sync-ToMinio.ps1` (uploads) and
  `validation/Test-Dependencies.ps1` (content-match) dot-source it, so the
  two scripts can never drift on which keys go where.

### Changed

- **`validation/Test-Dependencies.ps1`** report category extended:
  - `S3` rows = HEAD existence check (unchanged).
  - **`S3-Content`** rows = new MD5/ETag content-match per key.
  - Skipped gracefully for keys with no local file (binary tools uploaded
    out-of-band via USB) or for multipart uploads (ETag opaque).

---

## [2.4.0] -- 2026-04-28

Major feature release: new operator tool inventory, observability stack,
SSH-based remote control plane, OpenCode + WebView2 silent install,
graceful Hyper-V degradation, and a self-extending validation suite.

### Added

- **Table-driven tool installer** -- `scripts/Install-Tools.ps1` reads
  `$Script:Config.ToolPackages` (14 rows) and installs each tool with the
  right method (exe / msi / zip / copy / msixbundle), silent flag, detection
  probe, and optional PostInstall hook. Adding a tool means adding one row;
  no script edits.
  - **Tools delivered:** WinRAR, NSSM, Sysinternals, Notepad++, WinMerge,
    BareTail, Klogg, Everything (with indexer service), WizTree, System
    Informer 4.0, EventLook, Wireshark + tshark, Google Chrome, Windows
    Terminal (portable, configured as default UX for PS + CMD).
- **Observability stack** -- `scripts/Install-Observability.ps1` brings up
  four Prometheus scrape endpoints per runner:
  - `:9182` `windows_exporter` (MSI service) -- host metrics
  - `:9115` `blackbox_exporter` (NSSM service) -- ICMP/TCP/HTTP probes
  - `:9252` GitLab Runner built-in -- via `listen_address` in `config.toml`
  - `:9323` Docker daemon built-in -- via `metrics-addr` + `experimental:true`
    in `daemon.json`
  Inbound firewall rules opened for all four ports.
- **OpenCode desktop with WebView2 prerequisite** --
  `scripts/Install-OpenCode.ps1` silently installs WebView2 Evergreen runtime
  (hard prerequisite), then OpenCode itself via NSIS (`/S`), then publishes
  `opencode.jsonc` to the machine-wide path `C:\ProgramData\opencode\` and
  sets the `OPENCODE_CONFIG` Machine env var so every user reads the same
  config.
- **OpenSSH remote control plane** -- `scripts/Enable-RemoteSSH.ps1` replaces
  the prior WinRM step (`Enable-RemotePowerShell.ps1`, deleted) which was
  blocked by domain GPO. Installs OpenSSH-Win64 from a portable zip (no
  `Add-WindowsCapability`, no BITS, fully air-gapped), registers `sshd`,
  opens TCP 22, sets PowerShell as the default shell, writes a managed
  `sshd_config` block enabling AD password auth + optional `AllowGroups`
  whitelist (configurable via `OpenSshAllowedADGroups` in `Config.ps1`),
  and optionally seeds `administrators_authorized_keys` for SSH-key
  fallback.
- **Set-WindowsTerminalDefault.ps1** -- portable-mode Windows Terminal
  configuration. Drops a `.portable` marker, writes machine-wide
  `settings.json` to `<install_dir>\settings\`, replaces Default User Start
  Menu shortcuts for PowerShell and CMD with Terminal-launching ones, adds
  `wt` to PATH.
- **Auto-extending validation** -- `validation/Invoke-FinalValidation.ps1`
  now generates one validation check per row in `$Config.ToolPackages` plus
  dedicated checks for `sshd`, `windows_exporter`, `blackbox_exporter`,
  Docker `metrics-addr`, runner metrics firewall, WebView2, OpenCode config,
  and `OPENCODE_CONFIG` env var.
- **Hyper-V graceful skip across reboot** -- Phase 1 now detects VT-x
  exposure before attempting `Install-WindowsFeature -Name Hyper-V`. When
  the host doesn't expose nested virtualization, Phase 1 logs a clear WARN
  and writes `C:\GitLab-Runner\.hyperv_skipped`. Validation in Phase 3
  reads the marker (in-memory variables don't survive the Phase 1 -> 3
  reboot). Runner continues fine on docker-windows process isolation.
- **gitlab-runner stop/uninstall pre-check** -- Phase 3 step 3.8 now skips
  `stop`/`uninstall` when no service exists, eliminating the FATAL log
  noise on first install.
- **GitLab CI/CD verification stage** -- new `verify-minio` stage in
  `.gitlab-ci.yml` runs `validation/Test-Dependencies.ps1` after sync, so
  missing or forgotten S3 keys fail in CI rather than at first runner
  provision.
- **Fleet scripts now use OpenSSH** -- `fleet/Get-FleetHealth.ps1` and
  `fleet/Invoke-FleetCommand.ps1` rewritten to drive runners over OpenSSH
  instead of PSRemoting/WinRM. Support SSH key auth (recommended), AD
  password auth (per-host prompt), and GSSAPI/Kerberos. Health probe now
  also reports `sshd`, `windows_exporter`, and `blackbox_exporter` status.

### Changed

- **Path layout under `tools/` in MinIO** -- old flat keys
  (`tools/winrar-x64-701.exe`, `tools/nssm-2.24.zip`,
  `tools/sysinternals/procexp64.exe` and 3 siblings) replaced with
  per-tool subfolders (`tools/winrar/`, `tools/nssm/`,
  `tools/sysinternals/SysinternalsSuite.zip`). Old keys are not deleted by
  CI; they're harmless dead bytes.
- **`config.toml`** now includes `listen_address = ":9252"` for runner metrics.
- **`daemon.json`** now includes `metrics-addr: "0.0.0.0:9323"` and
  `experimental: true` (required for Docker metrics-addr in 25.x).
- **`ci/Sync-ToMinio.ps1`** `$FileMap` extended with the 4 new helper
  scripts and `Install-OpenCode.ps1`; `Enable-RemotePowerShell.ps1` removed.
- **`scripts/Write-GoldenVersion.ps1`** stamp now includes a `Tools`
  inventory (14 entries) and a `MetricsEndpoints` block.

### Removed

- **`scripts/Enable-RemotePowerShell.ps1`** -- obsolete WinRM bootstrap;
  the GPO that blocks WinRM service config means this script never worked
  reliably at Kayhut. Replaced by `scripts/Enable-RemoteSSH.ps1`.

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
