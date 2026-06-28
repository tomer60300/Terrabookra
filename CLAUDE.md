# CLAUDE.md — Terrabookra

GitLab Runner **golden-image provisioner** for an **air-gapped** Windows Server 2019 LTSC fleet.
PowerShell 5.1.

> **`terraform` branch (current): the build moved off Be1 to Packer + Terraform.**
> Packer builds ONE generic, **unregistered** golden image (phases run over SSH with `windows-restart`
> between them); Terraform deploys runners that **self-register at first boot** from vSphere `guestinfo`.
> MinIO is retired (artifacts via **Git LFS** + the uploaded repo tree); images come from the **GitLab
> Container Registry** (Harbor retired). `main` still holds the Be1 line as the rollback baseline — where
> this file's older "Be1 / MinIO / Harbor" wording still applies. See `docs/MIGRATION-STATUS.md` and
> `docs/MIGRATION-TO-TERRAFORM.md`.

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

## How a build runs (`terraform` branch — Packer/Terraform)
- **Packer is the orchestrator** (replaces Be1). `packer/base` builds a WS2019 template with OpenSSH
  baked in (autounattend); `packer/golden` clones it, uploads the repo (`file` provisioner), and runs
  `provisioners/Invoke-Phase.ps1 -Phase 1|2|3` over the **SSH communicator** with `windows-restart`
  between phases. **No `3010` self-reboot, no MinIO self-fetch, no marker dispatch** — Packer owns
  sequencing. Phases still set `.phaseN_complete` markers (existence-only) as idempotency, not the driver.
- **Phase 3 is build-time only** (`phases/Phase3-Install.ps1`, `Invoke-Phase3Install`): Docker verify,
  runner **binary** install, image pre-pull (GitLab registry), tools/observability, and a **token-less
  `config.toml` skeleton**. It does NOT resolve a token, register, or install the runner service — the
  image ships **generic + unregistered**.
- **First boot (deployed clone):** `provisioners/Register-RunnerFirstBoot.ps1` (SYSTEM startup task,
  installed at build) reads `guestinfo.runner_token` + `guestinfo.runner_hostname` via
  `vmtoolsd --cmd "info-get guestinfo.<k>"`, writes the final `config.toml`, registers if needed, and
  installs+starts the runner service. Idempotent + retry.
- **Two gates:** build-gate = `validation/Invoke-FinalValidation` (image-correctness; runs inside Phase 3,
  fails `packer build`); deploy-gate = `Test-RunnerRegistered` (service running + `gitlab-runner verify`
  + tasks/sshd/exporters; runs at first boot / CI acceptance).
- **Artifacts:** no MinIO. Binaries travel via **Git LFS** and are read from the uploaded repo tree
  (`Copy-RepoFile` / `Install-LocalBinary` / `Install-LocalArchive`). Images come from the **GitLab
  Container Registry**. The deployed fleet is queried from an admin PC over **SSH**, not WinRM.

## Repo layout
- `packer/` — `base/` (vsphere-iso + `autounattend.xml`, OpenSSH/SSH communicator) and `golden/`
  (vsphere-clone + repo upload + phase provisioners + build-gate). `example.pkrvars.hcl` are committed
  placeholders; real `*.auto.pkrvars.hcl` are gitignored.
- `terraform/` — vSphere clone-from-template fleet; `extra_config` guestinfo identity contract;
  `TODO(#12)` placement + `TODO(#13)` domain join; offline provider mirror (`terraform.rc`).
- `provisioners/` — `Invoke-Phase.ps1` (thin Packer entry → `Invoke-PhaseN`), `Register-RunnerFirstBoot.ps1`.
- `transfer/` — `Export-Transfer.ps1` / `Import-Transfer.ps1` (git bundle + LFS CAS over USB).
- `lib/Config.ps1` — settings; host vars read `$env:REAL_*` with `*.kayhut.com` alias defaults; artifact
  catalogs (`S3Keys`/`S3KeysExtra`/… are now **repo-relative paths**, not MinIO keys). `lib/Common.ps1`
  — logging, markers, local artifact helpers (`Get-RepoPath`/`Copy-RepoFile`/`Install-Local*`).
- `phases/` — `Phase1-SystemPrep`, `Phase2-DockerInstall`, `Phase3-Install` (build-time).
- `scripts/` — install + maintenance (`Install-Tools/OpenCode/Observability`, `Assert-Environment`,
  `Import-Certificates`, `Enable-RemoteSSH`, watchdogs, disk-monitor, health-check).
- `validation/` — `Test-BuildInputs` (preflight: LFS artifacts + registry), `Invoke-FinalValidation`
  (build-gate) + `Test-RunnerRegistered` (deploy-gate).
- `ci/` — `Validate-NoAliases` (alias-by-resolution invariant), `Invoke-AcceptanceGate`,
  `Publish-GoldenManifest`.
- `Bootstrap-GitLabRunner.ps1` — **retired stub** (Be1 entry point; deleted-soon).
- `fleet/` — SSH-based fleet health/command tools (run from an admin PC, not on runners).
- `docs/` — design + review notes (read for depth).

## Git & commit rules
- Commit author is **Tomer60300 <Tomer60300@gmail.com>**, with **no** Claude / Co-Authored-By /
  "Generated with" trailer:
  `git -c user.name='Tomer60300' -c user.email='Tomer60300@gmail.com' commit -F msg.txt`
- Flow (terraform branch): commit per task on `terraform`, push `terraform`; **never touch `main`**
  (it's the Be1 rollback baseline). Do **not** fast-forward `main` (the `ship` skill's main-FF step is
  dropped here).
- Pushing: the token var must be **exported** or the credential helper sends an *empty* password.
  The repo is **public**, so reads/`ls-remote` succeed even with a bad token — that masks an auth
  failure on push. Don't conclude "token revoked" from a failed push alone.

## Editing & verification (no PowerShell runtime here)
- You can't lint with `pwsh`. After editing any `.ps1`, verify with **both**:
  1. delimiter balance — `{} () []`, and
  2. **quote parity** — no unterminated `'`/`"`. A brace check *alone* once missed a stray quote
     (`$x = 0'`) that broke parsing of a whole script.
- Prefer exact-string patches; keep edits minimal and reviewable.
- A **PostToolUse hook** now automates this: editing any `.ps1` runs `.claude/verify-ps.ps1`
  on the **PS 5.1 engine** (`powershell.exe`) — `[Parser]::ParseFile` + PSScriptAnalyzer —
  and feeds parse/Error findings back. The manual brace/quote checks above are the fallback
  when the hook can't run. Run `.claude/verify-ps.ps1 -Path <file>` on demand; the `ship`
  skill runs it before every commit.

## Claude Code tooling (plugins & skills)
Enabled in `.claude/settings.json`; the repo also ships its own `ps-reviewer` agent and
`ship` skill. Adapt the plugins to this project's reality:
- **Superpowers** — keep its planning, **two-stage review**, and **root-cause debugging**
  as-is. But there is **no unit-test suite here**: wherever a skill's plan→test→code loop
  expects a failing test, read "the test" as **`verify-ps` passing + the relevant validation**
  (`validation/Invoke-FinalValidation` as the build-gate; `Test-RunnerRegistered` deploy-gate;
  `Test-BuildInputs` preflight; `Assert-Environment`). Verification is static — don't fabricate a
  unit-test harness to satisfy a skill.
- **HashiCorp Packer + Terraform skills** — for the Be1→Packer/Terraform work only
  (`docs/MIGRATION-TO-TERRAFORM.md`; `docs/BACKLOG.md` Epics 2–3). Use the **Windows-image**
  Packer skill and honor the constraints: air-gapped, WS2019/ltsc2019, **SSH communicator**
  (Packer defaults to WinRM, which is GPO-blocked — set SSH explicitly), least-priv vCenter
  (`svc-packer`/`svc-terraform`), offline provider/plugin mirrors. Don't apply the AWS/Azure
  builders as-is.
- **context7 MCP** — pull current Packer/Terraform/provider docs on demand. Dev-leg
  convenience (internet-only); never a production-leg dependency. Loads after a Claude restart.

## PS 5.1 pitfalls that have actually bitten this project
- **Non-terminating errors bypass `try/catch`** under `$ErrorActionPreference='Continue'`.
  Add `-ErrorAction Stop` (classic case: `Write-EventLog` when the event source may be absent).
- **`[Type]::GetType('Type, PartialAssembly')` returns `$null`** on WS2019 even when the type is
  usable. Use `Add-Type` then `'Type' -as [type]`.
- **`$LASTEXITCODE` is stale** after cmdlets/pipelines — reset it first, or run child scripts as a
  subprocess (`powershell.exe -File ...`) and read its exit.
- **skip-if-exists caches** can shadow an updated artifact — `Copy-RepoFile` always re-copies; don't add
  skip-if-exists to rotation-prone artifacts (CA certs / first-boot inputs).
- **`Write-EventLog` needs the `GitLabRunner` event source**, created by `Assert-Environment` in
  Phase 1. Guard with `[System.Diagnostics.EventLog]::SourceExists(...)` for off-host/CI runs.

## Current state & where to look
- **`terraform` is the working branch** (Epic 2: Be1 → Packer/Terraform, implemented — see
  `docs/MIGRATION-STATUS.md`). `main` is the untouched Be1 rollback baseline.
- Next manual step: smoke-test `packer build` + the Terraform deploy on a **lab vCenter** (reboot-resume
  under `windows-restart`, acceptance-gate pipelines) — not runnable on the dev/internet leg.
- Open: `TODO(#12)` vCenter placement + `TODO(#13)` domain-join facts block `terraform apply` only.
  Acceptance-gate pipeline triggers (`ci/Invoke-AcceptanceGate.ps1`) are a lab step.
- Known issue: golden-image **version stamp is hard-coded `2.4.0`** in Config; CI `promote` now derives
  `2.x.y+<gitsha>` from the build manifest (`ci/Publish-GoldenManifest.ps1`) — see `docs/BACKLOG.md` (Epic 1).
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
