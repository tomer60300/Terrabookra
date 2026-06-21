# Terrabookra — Review Backlog (Epics & Tasks)

Source: critical review of `main` @ `617abb2` + the Be1→Packer/Terraform design.
Priority: P1 = ship-blocker, P2 = fix soon, P3 = nice-to-have.
Estimates are for one engineer, rough.

---

## EPIC 1 — Harden the current Be1 pipeline
**Goal:** close the latent bugs the review found, on the existing branch→main flow.
**Size:** ~1–2 days total. No architecture change.

| ID | Task | Pri | Est | Done when |
|----|------|-----|-----|-----------|
| 1.1 | Guard `Write-EventLog` in the 4 maintenance scripts (`disk-monitor`, `docker-watchdog`, `health-check`, `kill-stale-containers`) with `SourceExists` + `-ErrorAction Stop` | P2 | 0.5d | Scripts run clean when the event source is absent; unchanged when present |
| 1.2 | Fix the golden-image version stamp — `GoldenImageVersion` is hard-coded `2.4.0`; derive it from one source (VERSION) so the built image reports its real version | P2 | 0.5d | A built image's manifest shows the actual version incl. recent fixes |
| 1.3 | Always re-fetch the CA in `Import-Certificates.ps1` (remove skip-if-exists) so a rotated cert isn't shadowed | P2 | 0.5d | Rotated CA under the same filename is re-downloaded on re-run |
| 1.4 | Replace WinRM `Invoke-Command` examples in docs (`Test-Dependencies`, `Export-RunnerLogs` `.NOTES`) with `ssh` | P3 | 15m | No `Invoke-Command` in usage examples |
| 1.5 | `Assert-Environment`: WARN when Harbor / GitLab-registry creds are empty or placeholder (today only MinIO is checked) | P3 | 0.5d | Preflight warns when those creds are unfilled |
| 1.6 | Wire OpenCode no-update (`"autoupdate": false` in jsonc + `OPENCODE_DISABLE_AUTOUPDATE=true` machine env in `Install-OpenCode`) | P3 | 0.5d | OpenCode makes no update attempt on startup |
| 1.7 | Document a rotation plan for the single runner token + registry token (blast-radius) | P3 | process | A written rotation/runbook entry exists |

---

## EPIC 2 — Be1 → Packer/Terraform POC (the spike)
**Goal:** Packer builds the WS2019 image in a *lab* vCenter, over SSH, reusing Phase 1–3, and it passes `Invoke-FinalValidation`.
**Out of scope:** Vault, least-priv finalization, Terraform fleet, full air-gap hardening.
**Size:** ~2–4 weeks (access + Packer experience are the swing factors).

| ID | Task | Pri | Est | Done when |
|----|------|-----|-----|-----------|
| 2.1 | Get lab vCenter + a service account; install Packer; hand-mirror the vSphere plugin (air-gapped) | P1 | 1–3d | `packer` runs offline with the plugin; can auth to lab vCenter |
| 2.2 | Build a WS2019 base template with OpenSSH pre-enabled (breaks the SSH chicken-and-egg) | P1 | 1–3d | Packer's SSH communicator connects on first boot |
| 2.3 | Author the Packer template: clone template → SSH → Phase 1/2/3 provisioners → `windows-restart` between phases; strip the Be1 exit-3010/self-reboot glue | P1 | 2–4d | Build runs the three phases in order |
| 2.4 | Make reboot-and-resume work under `windows-restart` (iterate timing/order) — the riskiest chunk | P1 | 2–5d | All 3 phases complete across reboots with no manual steps |
| 2.5 | Wire MinIO/Harbor + temp creds; run `Invoke-FinalValidation` as the build gate until green | P1 | 3–5d | Image builds and passes validation (= equivalence gate) |

---

## EPIC 3 — Production hardening + cutover (post-POC)
**Goal:** make the new pipeline secure, least-privilege, air-gap-clean, and deployable; retire Be1.
**Size:** several weeks; do only after the POC proves the model.

| ID | Task | Pri | Est | Done when |
|----|------|-----|-----|-----------|
| 3.1 | Secrets backend (Vault, or sealed `sensitive` vars + `guestinfo`); remove placeholder-edit creds + duplicated bootstrap keys | P1 | L | No secret lives in Git; image carries none |
| 3.2 | Least-priv vCenter roles: `svc-packer` (build) + `svc-terraform` (deploy), scoped to folders | P1 | M | Neither account is vCenter Administrator |
| 3.3 | Offline provider/plugin mirrors + pinned versions, wired into GitLab CI | P2 | M | `terraform`/`packer` init succeed air-gapped in CI |
| 3.4 | Terraform module: deploy runner fleet from the template + secure (encrypted, locking) state | P1 | L | `terraform apply` stands up a registered runner |
| 3.5 | Parallel-run: build via Be1 and Packer; automated component/config diff + canary runner on real jobs | P1 | M | Diff is clean; canary runs production jobs |
| 3.6 | Cutover: bless the Packer image as source of truth, keep Be1 as fallback N weeks, then remove exit-3010/markers and decommission | P1 | M | Be1 retired; rollback path documented |

---

## Suggested order
1. **Epic 1** now (quick, independent, reduces noise). 
2. **Epic 2** POC (proves the approach; low risk — reuses your scripts).
3. **Epic 3** only after the POC's equivalence gate is green.

## Not tasks (verified clean in the review)
`Test-Dependencies` exits with its fail count · Phase 1 runs validators as subprocesses (reliable exit codes) · `docker-watchdog`/`Install-Tools` exit-code handling is sound · no internet calls (WebClient targets MinIO; the `aka.ms` URL is a non-fetched schema string) · no WinRM at runtime.
