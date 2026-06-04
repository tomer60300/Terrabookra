# Terrabookra — Full Code Review & Optimization

**Scope:** 30 PowerShell files, ~6,140 LOC (core, phases, scripts, validation, ci, fleet),
reviewed by 5 parallel reviewers + manual verification against source.

**Version baseline:** GitHub `main` = **2.4.6** (what was reviewable end-to-end). You run
**2.4.7i**. Findings in files your 2.4.7 stack rewrote — `lib/Common.ps1`,
`Bootstrap-GitLabRunner.ps1`, `phases/*`, `scripts/Install-Tools.ps1` — are tagged
**⚠ VERIFY-2.4.7i**: apply only if your copy still matches; some may already be fixed by
2.4.8–2.4.11.

**Legend:** ✅SHIPPED = corrected file in `fixes/`. 🔧PATCH = copy-paste fix below.
⚠VERIFY = version-sensitive.

The three Cluster fixes (Install-Tools, Install-OpenCode, Install-Observability) and these
two are already in `fixes/`. Everything else is a 🔧PATCH here.

---

## Shipped this pass (version-stable, drop-in)

- **Register-ScheduledTasks.ps1** — M1 + M2 below.
- **disk-monitor.ps1** — M3 below.

---

## HIGH

### H1 — Completed phases silently re-run (marker staleness) 🔧PATCH ⚠VERIFY
`lib/Common.ps1:284` + `lib/Config.ps1:132`. `Test-PhaseComplete` deletes a phase marker
older than `StaleMinutes = 60` and re-runs the phase. Markers are written at phase *completion*
and must survive reboots; if any phase boundary (Be1 queue, slow datastore, GPO, operator
delay) exceeds 60 min, an already-completed phase re-runs from scratch.
**Fix (safe, version-stable — Config only):**
```
StaleMinutes = 1440   # was 60; markers represent durable completion, not liveness
```
Conceptually phase-completion markers shouldn't expire at all; the Config bump is the
low-risk fix without touching the 2.4.7 `Common.ps1`.

### H2 — Pre-flight gate false-PASS on the bootstrap (when `BOOTSTRAP_S3_PATH` set) 🔧PATCH
`validation/Test-Dependencies.ps1:248-256` swaps the bootstrap key to the alt key in the
existence list, but `$Script:S3KeyToRepoPath` stays keyed by the original name, so the MD5
content-match at `:386` is skipped for the alt-bucket bootstrap — a wrong/stale bootstrap
(the exact file Be1 fetches) reports **S3-Content PASS**.
**Fix:** right after `$Script:BootstrapAltKey = ...`:
```powershell
if ($Script:S3KeyToRepoPath.ContainsKey($Script:BootstrapDefaultKey)) {
    $Script:S3KeyToRepoPath[$Script:BootstrapAltKey] = $Script:S3KeyToRepoPath[$Script:BootstrapDefaultKey]
    [void]$Script:S3KeyToRepoPath.Remove($Script:BootstrapDefaultKey)
}
```

### H3 — Air-gap dependency gate silently bypassed on fetch failure 🔧PATCH ⚠VERIFY
`phases/Phase1-SystemPrep.ps1:43`: `Get-S3Object ... | Out-Null` discards the `[bool]` result;
if the fetch of `Test-Dependencies.ps1` fails, `Test-Path` is false → warn-and-skip, so
provisioning proceeds with **no pre-flight DNS/S3/Harbor check**. (Same unchecked-return
pattern recurs: Phase1 182/210/214/221, Phase3 321/350/417-419/450-451.)
**Fix:**
```powershell
if (-not (Get-S3Object -Key $Script:Config.S3KeysExtra.DepValidator -OutFile $depScriptLocal)) {
    Write-LogError 'FATAL: cannot fetch Test-Dependencies.ps1 — aborting'; throw 'dep-validator fetch failed'
}
```

---

## MEDIUM

### M1 — `health-check.ps1` staged but never scheduled ✅SHIPPED
`scripts/Register-ScheduledTasks.ps1` registered 12 tasks; none invoked `health-check.ps1`
(staged by Phase3:305). Its own header claims a 5-minute task that didn't exist — events
9005-9008 never fired. Added a `Health-Check` task (5-min). *(Delete that one entry if you
intended health-check to be on-demand.)*

### M2 — Scheduled tasks had no `-Settings` ✅SHIPPED
Default `ExecutionTimeLimit` is **3 days** — long enough to kill a big emergency
`docker system prune`; missed `-Once/00:00` triggers didn't run after boot. All tasks now use
`ExecutionTimeLimit=0` (unlimited) + `StartWhenAvailable` + `MultipleInstances IgnoreNew`.

### M3 — `disk-monitor.ps1` could prune a healthy host ✅SHIPPED
`:49` `(Get-PSDrive $drv).Free` → `$null` if the drive can't be queried; `$null -lt 10` is
`$true` in PS 5.1 → spurious `docker system prune --all --force`. Now guarded
(`Get-FreeGB` returns `$null` → drive skipped, never pruned).

### M4 — SigV4 signed once, before the retry loop 🔧PATCH ⚠VERIFY
`lib/Common.ps1:93-126` computes the timestamp/signature *outside* the `for ($attempt...)` at
`:132`. Retries reuse a stale `x-amz-date`; on a slow first attempt this risks
`RequestTimeTooSkewed`, and a re-sign per attempt is the robust pattern.
**Fix:** move the whole signing block (timestamp → `$authHeader`) inside the `for` loop.

### M5 — `WebClient` follows redirects and resends `Authorization` 🔧PATCH ⚠VERIFY(Common)
`lib/Common.ps1:138`, `Bootstrap:161`, `ci/Sync-ToMinio.ps1`, `Test-Dependencies`. `WebClient`
auto-follows 3xx and resends headers with the original Host-bound SigV4 signature → fails (or
fetches an unintended host) the moment MinIO sits behind a proxy/LB.
**Fix:** use `HttpWebRequest` with `.AllowAutoRedirect = $false` (treat 3xx as error), or a
`WebClient` subclass overriding `GetWebRequest` to set `AllowAutoRedirect=$false`. *(2.4.9 P3
already did this for the Common HttpWebRequest path — verify yours; the `ci/*` copies still
need it.)*

### M6 — `docker login` exit code unchecked 🔧PATCH ⚠VERIFY
`phases/Phase3-RunnerSetup.ps1:131-133`. On login failure the script logs the error but still
launches all pulls; failure only surfaces ~10 min later. (Block is skipped today because
`HarborUser/Pass` are empty — anonymous pull assumed; if Harbor ever needs auth, every pull
fails late.)
**Fix:** after the login pipe, `if ($LASTEXITCODE -ne 0) { Write-LogError 'FATAL: docker login failed'; exit 1 }`.

### M7 — Phase 3 re-fetches OpenCode/WebView2 every run 🔧PATCH ⚠VERIFY
`phases/Phase3-RunnerSetup.ps1:417-419` fetch unconditionally with `| Out-Null` (no skip-if-exists,
no result check) — wasteful on re-run and feeds a possibly-missing file to the installer.
**Fix:** mirror step 3.9 (skip if present, check the boolean, skip the Install-OpenCode call if any staging download failed).

### M8 — Final validation gates `C:` even when data lives on `E:` 🔧PATCH
`validation/Invoke-FinalValidation.ps1:90-94`. The `E:` free-space check is opportunistic and
independent of `$Script:DataDrive`, while `C:` is always hard-gated.
**Fix:** drive the data-disk check off `$Script:DataDrive`:
```powershell
$dd = $Script:DataDrive.TrimEnd(':'); if ($dd -ne 'C') { Check "Disk free ${dd}: >= 50 GB" { [math]::Round((Get-PSDrive $dd).Free/1GB) -ge 50 } }
```

### M9 — `Test-NetworkConnectivity.ps1` CSV not quoted 🔧PATCH
`:103` hand-builds CSV rows (`"$now,$host_,...`); any field with a comma shifts columns and
breaks the documented `Import-Csv` consumption.
**Fix:** emit a `[pscustomobject]` per row and `Export-Csv -Append -NoTypeInformation` (PS 5.1
supports `-Append`).

### M10 — `Invoke-FleetCommand.ps1` password fan-out hangs 🔧PATCH
`:104-125`. `ssh` runs inside `Start-Job` (no TTY) so interactive AD-password auth can't prompt —
it errors or hangs; `Wait-Job` has no timeout, so one stuck host blocks the whole run.
**Fix:** run the password path sequentially in the foreground (like `Get-FleetHealth.ps1`), or
force `-o BatchMode=yes` in the job; add `Wait-Job -Timeout <n>` and treat timeouts as failures.

### M11 — `Install-Observability` NSSM `set` results unchecked 🔧PATCH
The fire-and-forget `Start-Service` and missing-binary cases are fixed in
`fixes/Install-Observability.ps1`, but the five `& $nssm set ... | Out-Null` calls still ignore
`$LASTEXITCODE` — a failed `set AppParameters` leaves the service mis-parameterized.
**Fix:** after each `nssm set`, `if ($LASTEXITCODE -ne 0) { Write-Step "WARN: nssm set <prop> exit $LASTEXITCODE" 'WARN' }`.

---

## LOW

### L1 — Nested `HmacSHA256` leaks to script scope 🔧PATCH ⚠VERIFY(Common)
`lib/Common.ps1:113`, `Bootstrap:136`, `ci/Sync-ToMinio.ps1:124`. Helper defined *inside*
`Get-S3Object`; PS 5.1 leaks nested defs to parent scope (the project's own pitfall).
**Fix:** hoist to a single script-scope `function HmacSHA256 {…}` defined once near the top.
*(2.4.11 CR1 did this in Common — you're on 2.4.7i, so likely still nested; the `ci/` copy needs it regardless.)*

### L2 — `Set-WindowsTerminalDefault.ps1` PATH substring match 🔧PATCH
`:151` `if ($currentPath -notlike "*$InstallDir*")` — a longer existing entry
(`…\WindowsTerminal\bin`) is a false positive, so `wt` never gets added.
**Fix:** `if (($currentPath -split ';') -notcontains $InstallDir) { … }`.

### L3 — `Import-Certificates.ps1` `.Count` guard unreliable 🔧PATCH
`:70-74` — single/zero matches make `$certFiles.Count` `$null` in PS 5.1.
**Fix:** `$certFiles = @(Get-ChildItem … | Where-Object {…})` so `.Count` is always an int.

### L4 — `Export-RdpAuditLog.ps1` duplicates boundary events 🔧PATCH
`:89-93` `Get-WinEvent -FilterHashtable @{ StartTime=$since }` is inclusive; the last event of
the prior run (marker written `:111`) re-emits.
**Fix:** capture the run start time *before* querying and write that as the marker, or de-dupe by RecordId.

### L5 — `Write-GoldenVersion.ps1` can stamp garbage Docker version 🔧PATCH
`:54` `docker version --format '{{.Server.Version}}' 2>$null` against a down daemon can return
`<no value>`/error text rather than falling to `'unknown'`.
**Fix:** `$v = docker version --format '{{.Server.Version}}' 2>$null; $dockerVersion = if ($LASTEXITCODE -eq 0 -and $v) { $v } else { 'unknown' }`.

### L6 — `Test-Dependencies.ps1` header read after `.Close()` / missing-ETag silent PASS 🔧PATCH
`:328-333` reads `$response.Headers['ETag']` after `$response.Close()` (works today, fragile —
move the read before Close). `:399-402` treats a missing ETag as content PASS — make it a WARN.

### L7 — `$Matches` leak in token handling (defensive)
`phases/Phase3-RunnerSetup.ps1:171,207`. Not load-bearing today; set `$Matches=$null` before the
second `-match`, or use `[regex]::Match()`.

---

## OPTIMIZATIONS

- **O1** `Test-Dependencies.ps1:258-260` adds `S3Bootstrap` keys with no de-dup guard → duplicate
  HEAD checks + inflated pass count. Fix: iterate `($allS3Keys | Sort-Object -Unique)`.
- **O2** `ci/Sync-ToMinio.ps1:138` & `Test-Dependencies` build the request URL from raw `$Key`
  while signing `$encodedKey` — latent `SignatureDoesNotMatch` for any key with a space/`+`.
  Fix: build the URL from the encoded path so signed and requested agree.
- **O3** `health-check.ps1` / `docker-watchdog.ps1` run full `docker info` every few minutes;
  use `docker info --format '{{.ID}}'` (still sets `$LASTEXITCODE`).
- **O4** `kill-stale-containers.ps1` / `health-check.ps1` `[datetime]::Parse` is culture-sensitive
  (silently skips containers on non-en-US locale). Use
  `[datetime]::Parse($s,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)`.
- **O5** `ci/Validate-NoAliases.ps1:49` `Substring($Path.Length)` breaks if `-Path` has a trailing
  separator. Fix: `$base=(Resolve-Path $Path).Path.TrimEnd('\','/')`.
- **O6** Minor: dispose crypto objects in `Get-S3Object`; `Phase1` `LongPathsEnabled` write lacks
  `-EA SilentlyContinue` and the `HKCU` cosmetic tweaks don't apply under SYSTEM; `Phase2:121`
  fixed 10s sleep → reuse `Wait-ServiceRunning`; `Config.HarborUrl` is scheme-less (consider
  renaming `HarborHost` for clarity); add "KEEP IN SYNC" comments on the duplicated
  `Get-BootstrapS3Object` ↔ `Get-S3Object` signing blocks.

---

## What was checked and is correct (no action)

SigV4 signing math (canonical request, signed headers, host+port, key-derivation) in
`Get-S3Object` and `Sync-ToMinio`; alias-substitution ordering (no greedy/substring collisions);
`Enable-RemoteSSH.ps1` (idempotent marker-block rewrite, ASCII/no-BOM `sshd_config`);
`Export-RunnerLogs.ps1`; the `Host`/`Port` JSON round-trip in `Test-NetworkConnectivity`;
`Get-FleetHealth.ps1` JSON probe depth. Intentional by design (not flagged): TLS bypass,
insecure registries, trust-all-certs, placeholder credentials.
