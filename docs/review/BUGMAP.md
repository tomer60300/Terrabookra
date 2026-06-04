# Terrabookra — Bug Map (Pass 3: state machine + adversarial self-review)

Two red-team passes: (A) the reboot/phase **state machine** (not line-reviewed before),
and (B) adversarial re-review of the **fixes already shipped** in this folder. Findings
verified against source. State-machine items live in your 2.4.7-rewritten files → **⚠VERIFY**
before applying; the self-review corrections are version-stable and **already re-applied**.

---

## A. New state-machine findings (Bootstrap / phases — ⚠VERIFY-2.4.7i)

### N1 — No Phase-3 completion marker + no terminal `exit 0` (HIGH)
There is **no `Phase3Marker`** anywhere, and Bootstrap dispatch (`:288-299`) has no "all done"
branch. Once `Phase2Marker` exists, **every** Be1 re-trigger re-runs all of Phase 3. Phase 3
has late hard-exits — Harbor pre-pull `exit 1` (`Phase3:~499`) and the registration gate
`exit 1` (`Phase3:522`). So a transient pull blip or a momentary `gitlab-runner` not-Running
on a **healthy, finished** box makes Bootstrap tell Be1 the VM is "NOT operational," and Be1
stops a working machine. If the Phase2 marker has aged past `StaleMinutes`, dispatch instead
silently falls **all the way back to Phase 1**.
**Fix (patch):**
```powershell
# lib/Config.ps1 — add alongside the other markers
Phase3Marker = 'C:\GitLab-Runner\.phase3_complete'

# phases/Phase3-RunnerSetup.ps1 — replace the final success log with:
if ($Script:RunnerRegistrationFailed) {
    Write-LogError '... RUNNER IS DEGRADED ...'; exit 1
} else {
    Set-PhaseMarker $Script:Config.Phase3Marker      # only on a clean run
    Write-Log '========== PHASE 3 COMPLETE -- RUNNER IS OPERATIONAL =========='
}

# Bootstrap-GitLabRunner.ps1 — first dispatch branch, before the Phase2 check:
if (Test-PhaseComplete $Script:Config.Phase3Marker) {
    Write-Log 'All phases complete -- VM already provisioned. Nothing to do.'; exit 0
}
```

### N2 — Phase 0 trusts cached project files on `Test-Path` alone (MED)
`Invoke-Phase0` (`Bootstrap:223`) skips any file that exists, with no size/content/parse check —
`Get-BootstrapS3Object`'s 0-byte/XML guards run only on the *download* path. A prior run
interrupted mid-write (a scheduled reboot firing while Phase 0 is still streaming `Common.ps1`)
leaves a **truncated** lib file that is then dot-sourced (`:275-280`), so a function like
`Set-PhaseMarker` may be undefined → cryptic `CommandNotFoundException` deep in a phase.
**Fix (patch):** validate the cached file before SKIP, re-download if invalid:
```powershell
if (Test-Path $absPath) {
    $ok = $false
    try {
        if ((Get-Item $absPath).Length -gt 0) {
            $perr = $null
            [void][System.Management.Automation.PSParser]::Tokenize((Get-Content $absPath -Raw),[ref]$perr)
            $ok = (-not $perr) -or ($perr.Count -eq 0)
        }
    } catch { $ok = $false }
    if ($ok) { Write-BootstrapLog "  SKIP (exists, valid): $relPath"; $skipped++; continue }
    Write-BootstrapLog "  Cached file invalid -- re-downloading: $relPath" 'WARN'
    Remove-Item $absPath -Force -ErrorAction SilentlyContinue
}
```

### N3 — Phase 1 sets its marker even when required aux fetches were skipped (MED)
The cert-import and SSH-enable fetches (`Phase1:~182, ~210-221`) use
`Get-S3Object … | Out-Null` and fall through to a WARN-and-skip on failure, yet Phase 1 still
reaches `Set-PhaseMarker` (`:241`). A brief MinIO blip → the CA cert is never imported and SSH
never enabled, but the marker records Phase 1 "complete" and it is never revisited.
**Fix (patch):** for *required* components, check the boolean and `exit 1` (don't set the marker)
so Be1 re-attempts Phase 1; downgrade genuinely-optional fetches to logged ERROR.

### N4 — `$Script:RunnerRegistrationFailed` never initialized to `$false` (LOW)
Only ever assigned `$true` (`Phase3:213/219/296`); the gate (`:224/:522`) relies on "unset == ok."
A stray assignment or a typo'd name silently disables degraded-detection.
**Fix:** `$Script:RunnerRegistrationFailed = $false` as the first line of `Invoke-Phase3`.

### N5 — `Test-PhaseComplete` deletes a stale marker with no `-ErrorAction` (LOW)
`Common.ps1:285` `Remove-Item $Path -Force` — if the marker is transiently locked (Defender
scan during Phase 1/2, before Defender is configured), the throw propagates to the MAIN `catch`
→ `exit 1`, turning a benign "treat as incomplete, re-run" into a hard Be1 stop.
**Fix:** `Remove-Item $Path -Force -ErrorAction SilentlyContinue` and `return $false` regardless.

### Checked and dismissed (not bugs)
- *Phase 1 sets its marker before the inline `Invoke-Phase2`* — **correct**: the marker means
  "Phase 1 finished," which it has; if the inline Phase 2 fails, re-dispatching Phase 2 is right.
- *`Invoke-Be1Reboot` uses `shutdown /r /t 15`* — the 15 s grace is intentional (lets logs flush).

---

## B. Corrections to previously-shipped fixes (version-stable — RE-APPLIED this pass)

| # | File | Was | Now |
|---|---|---|---|
| C1 (HIGH) | Register-ScheduledTasks.ps1 | `-ExecutionTimeLimit ([TimeSpan]::Zero)` (PT0S "no limit" is ambiguous; a 0-second misread would kill the watchdogs/prune instantly) | `-ExecutionTimeLimit (New-TimeSpan -Days 3650)` — unambiguous, can't be read as "kill now" |
| C2 (MED) | Install-Observability.ps1 | `Start-ServiceWithRetry` polled a non-existent service for the full 30 s | early-return `if (-not (Get-Service …)) { return $false }` |
| C3 (MED) | Assert-Environment.ps1 | fixed-drive check defaulted `$isFixed=$true` → **failed open** on a null `DriveType` | positive assert: `Fixed`=PASS, `Removable`/`CD-ROM`=FAIL, unknown=WARN |
| C4 (MED) | Install-OpenCode.ps1 | unbounded `Get-ChildItem -Recurse` over all of Program Files, 2-3×/run | known leaf folders first, then `-Depth 3` bounded fallback |
| C5 (LOW) | Install-Tools.ps1 | `copy` kind hard-mapped to `exe` magic → a future non-PE copy would be falsely rejected | `copy` derives the magic kind from the DestPath extension (else `any`) |

All six scripts in this folder re-pass the structural parser after these edits.

---

## Master map (all three passes, by blast radius)

| Blast radius | Findings | Where |
|---|---|---|
| **Bricks/loops the build** | Cluster 1 staging (fixed); N1 re-run/false-degraded; N2 corrupt cached lib; marker staleness H1 | fixes/ + REVIEW.md H1 + BUGMAP N1/N2 |
| **Silent partial provision** | N3 cert/SSH skipped-but-marked-done; H3 dep-gate bypass; M1 health-check never scheduled (fixed) | BUGMAP N3 + REVIEW.md H3/M1 |
| **Won't start on unknown host** | placeholder creds G1; no early OS/PS guard G2; data-drive G5 | ENV-REVIEW.md + Assert-Environment.ps1 |
| **Feature degraded, runner still works** | OpenCode detection (fixed); exporters (fixed); Harbor anon M6 | fixes/ + REVIEW.md M6 |
| **Latent / hardening** | N4, N5, SigV4-once, redirect, nested-Hmac, CSV, fleet, etc. | BUGMAP + REVIEW.md |

**Priority order to apply:** N1 (terminal marker) → N2 (cached-file validation) → the
ENV-REVIEW placeholder-cred + `Assert-Environment.ps1` wiring → N3 → the already-shipped
fixes/ files → N4/N5 and the remaining REVIEW.md patches.
