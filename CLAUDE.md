# CLAUDE.md — Terrabookra

GitLab Runner **golden-image provisioner** for an **air-gapped** Windows Server 2019 LTSC fleet.
PowerShell 5.1. Built on the production leg by VMware Aria ("Be1") via VMware Tools guest operations, with reboots between phases.

## Two environments — know which leg you're on
This project lives in **two separate worlds**. Getting this wrong is the #1 source of confusion.

- **Dev leg — public GitHub, internet-connected. This is almost certainly where Claude Code runs.**
  Repo `github.com/tomer60300/Terrabookra`. Uses **alias** hostnames (`*.kayhut.com`) and the
  **alias project name "Terrabookra"**. Creds in `lib/Config.ps1` are **placeholders** (`YOUR_*`).
  The air-gapped infra (MinIO/Harbor/GitLab/Be1) is **NOT reachable from here**. Aliases and
  placeholders are *correct* on this leg — do **not** replace them with real values.
- **Production leg — the air-gapped Kayhut network. Where it actually runs.**
  Internal GitLab (16.7.10-ee, self-managed), Harbor (`:443`), MinIO (`:9000`, bucket
  `gitlab-runner-golden`), Be1 (VMware Aria), and the WS2019 runner VMs. **Real**
  hostnames, **real** creds, and the internal project name is **`Runners-Infra`** (not "Terrabookra").
  No internet.
- **Bridge:** code flows GitHub → **USB** → internal GitLab → MinIO. We have visibility into the
  GitHub leg only. CI runs on the *internal* repo: `validate-no-aliases` (FAILS if any `*.kayhut.com`
  or "Terrabookra" leaks into the internal copy) → `sync-to-minio` (SigV4 upload) → `verify-minio`.
  Internal repo = real hostnames; public repo = aliases. Operator fills real creds on the internal copy.

## Non-negotiable constraints
- **PowerShell 5.1 only** — no PS7 syntax/cmdlets. Target is WS2019 (build 17763).
- **Air-gapped** — no internet on the production leg. Artifacts come from MinIO (S3/SigV4); images
  from Harbor. Never add code that reaches the public internet.
- **WS2019 host + ltsc2019 containers, process isolation.** 2022/2025 = TODO only — do not implement.
- **WinRM is GPO-blocked** at Kayhut. SSH (OpenSSH) is the remote control plane (enabled by Phase 1
  step 1.11; fleet management uses SSH too). Do not reintroduce WinRM / `Invoke-Command`.

## How a build runs (production leg)
- **Be1 (VMware Aria)** creates the VM, domain-joins it + sets DNS, injects `GITLAB_RUNNER_TOKEN`,
  fetches `Bootstrap-GitLabRunner.ps1` from MinIO, and runs it **via VMware Tools guest operations**
  (not SSH/WinRM), powering the VM back on after each reboot. SSH is the *post-provision* control
  plane (fleet/admin access) — a separate thing from how Be1 triggers the build.
- **Exit-code contract with Be1:** `3010` = reboot/power-back-on, `0` = done, `1` = fail (Be1 stops).
- **Phases:** 0 = fetch bootstrap files from MinIO · 1 = system prep (→reboot) · 2 = Docker install
  (→reboot) · 3 = runner setup + final validation. `.phaseN_complete` markers drive resume and are
  **durable** (existence-only; a crash mid-phase leaves no marker and re-runs naturally).
- The finished golden image is a **GitLab Runner** that runs CI jobs in **ltsc2019 Windows containers
  (docker-windows executor, process isolation)**. The deployed fleet is queried from an admin PC over
  **SSH** (`fleet/Get-FleetHealth`, `Invoke-FleetCommand`), not WinRM.

## Repo layout
- `Bootstrap-GitLabRunner.ps1` — orchestrator, self-contained Phase 0 fetch, phase dispatch. (Cannot
  depend on `lib/Common.ps1` — it *fetches* it; the SigV4 signing logic is duplicated on purpose.)
- `lib/Config.ps1` — all settings, creds (placeholders), S3 keys, host aliases. `lib/Common.ps1` —
  logging, markers, S3 fetch (`Get-S3Object`).
- `phases/` — `Phase1-SystemPrep`, `Phase2-DockerInstall`, `Phase3-RunnerSetup`.
- `scripts/` — install + maintenance (`Install-Tools/OpenCode/Observability`, `Assert-Environment`,
  `Import-Certificates`, `Enable-RemoteSSH`, watchdogs, disk-monitor, health-check).
- `validation/` — `Test-Dependencies` (preflight), `Invoke-FinalValidation` (Phase 3 gate).
- `ci/` — `Sync-ToMinio`, `Validate-NoAliases`, `Substitute-Aliases`, `FileMap`.
- `fleet/` — SSH-based fleet health/command tools (run from an admin PC, not on runners).
- `docs/` — design + review notes (read for depth).

## Git & commit rules
- Commit author is **Tomer60300 <Tomer60300@gmail.com>**, with **no** Claude / Co-Authored-By /
  "Generated with" trailer:
  `git -c user.name='Tomer60300' -c user.email='Tomer60300@gmail.com' commit -F msg.txt`
- Flow: commit on `hardening/2.4.6-cluster-and-review`, push, then fast-forward `main`.
- Pushing: the token var must be **exported** or the credential helper sends an *empty* password.
  The repo is **public**, so reads/`ls-remote` succeed even with a bad token — that masks an auth
  failure on push. Don't conclude "token revoked" from a failed push alone.

## Editing & verification (no PowerShell runtime here)
- You can't lint with `pwsh`. After editing any `.ps1`, verify with **both**:
  1. delimiter balance — `{} () []`, and
  2. **quote parity** — no unterminated `'`/`"`. A brace check *alone* once missed a stray quote
     (`$x = 0'`) that broke parsing of a whole script.
- Prefer exact-string patches; keep edits minimal and reviewable.

## PS 5.1 pitfalls that have actually bitten this project
- **Non-terminating errors bypass `try/catch`** under `$ErrorActionPreference='Continue'`.
  Add `-ErrorAction Stop` (classic case: `Write-EventLog` when the event source may be absent).
- **`[Type]::GetType('Type, PartialAssembly')` returns `$null`** on WS2019 even when the type is
  usable. Use `Add-Type` then `'Type' -as [type]`.
- **`$LASTEXITCODE` is stale** after cmdlets/pipelines — reset it first, or run child scripts as a
  subprocess (`powershell.exe -File ...`) and read its exit.
- **skip-if-exists caches** can shadow an updated artifact in MinIO — re-fetch bootstrap-controlled files.
- **`Write-EventLog` needs the `GitLabRunner` event source**, created by `Assert-Environment` in
  Phase 1. Guard with `[System.Diagnostics.EventLog]::SourceExists(...)` for off-host/CI runs.

## Current state & where to look
- `main` is the live branch (check `git log`). Recent work: fatal Phase 1 SSH/cert gates, durable
  markers, GitLab Container Registry `docker login` (Phase 3.5, non-fatal + verbose), CI/event-log fixes.
- Known issue: golden-image **version stamp is hard-coded `2.4.0`** — see `docs/BACKLOG.md` (Epic 1).
- Depth: `docs/ARCHITECTURE.md`, `docs/DEPENDENCIES.md`, `docs/review/REVIEW.md`/`ENV-REVIEW.md`/`BUGMAP.md`;
  `docs/MIGRATION-TO-TERRAFORM.md` (Be1→Packer/Terraform plan); `docs/BACKLOG.md` (open epics/tasks).
- **Stale doc warning:** the workspace `HANDOVER.md` (2026-05-05) describes an older **WinRM** design,
  an event provider named "Terrabookra", and a 2.4.7–2.4.11 commit stack on
  `feature/2.4.8-postreboot-readiness` that is **not in `main`**. `main` is the 2.4.6 line + the
  hardening work. Trust `main` + this file over the handover where they conflict.

## Out of scope (don't reintroduce without asking)
WinRM / PSRemoting (GPO-blocked — SSH replaced it) · VMware Aria emulation · demo VMs ·
AD / DNS server / AD CS creation · HTTPS/TLS CA management · multi-2022/2025 support (TODO only).
The `C:\integ\` orchestrator on the STORE machine is a different system — not this repo's territory.

## Conventions
- Keep this file under ~200 lines (it loads every session). Put depth in `docs/` and point here.
- Maintenance scripts run as SYSTEM via scheduled tasks on the provisioned host.
- `Config.ps1` creds are placeholders in the public repo; real values are filled on the internal copy.
- Owner Tomer ("Store") is terse and parity-focused: match production exactly; don't re-explain settled
  decisions; bias to action.
