# Migration status — Be1 → Packer/Terraform (`terraform` branch)

Living tracker for the additive restructure on the `terraform` branch. `main` (the Be1 line) is the
untouched rollback baseline. Dev/internet leg only — verification is static (`verify-ps` / parity check,
`packer`/`terraform validate`, `Validate-NoAliases`). Lab-vCenter smoke tests are the next manual step.

## Confirmed decisions
1. **Build = generic, unregistered image.** Identity + registration happen at first boot from vSphere
   `guestinfo` (`vmtoolsd --cmd "info-get guestinfo.<k>"`).
2. **Two gates.** Build-gate = image-correctness subset of `Invoke-FinalValidation`; acceptance-gate =
   CI deploys one runner and runs representative pipelines.
3. **Aliases by name resolution**, not byte-substitution. `Config.ps1` reads `$env:REAL_*` with the
   `*.kayhut.com` alias as default.
4. **Thin orchestration.** Packer is the orchestrator; phases stay intact and standalone-runnable.
5. **Images move to the GitLab Container Registry; Harbor retired.** MinIO removed; build binaries via
   Git LFS.
6. **`terraform` is the GitHub default branch**; `main` never touched.

## Task progress
| Task | Status | Notes |
|---|---|---|
| Setup (branch/default/.gitignore) | partial | branch + .gitignore done locally; **remote push + default-branch flip BLOCKED** (session credential is read-only for the GitHub repo → push 403; `gh` absent). Operator must push `terraform` and set it default from their terminal. |
| T01 scaffold + this doc | done | `packer/ terraform/ provisioners/ transfer/` created |
| T02 Config env-aliases + retire Harbor | done | `$env:REAL_*` defaults; Harbor → GitLab Container Registry |
| T03 Phase3-Install split + artifact rewire | done | build-time only; local helpers (`Copy-RepoFile`/`Install-Local*`); token-less skeleton |
| T04 first-boot registration | done | `provisioners/Register-RunnerFirstBoot.ps1` + SYSTEM startup task; guestinfo contract |
| T05 validation split | done | build-gate `Invoke-FinalValidation` + deploy-gate `Test-RunnerRegistered` |
| T06 Packer templates | done | `packer/base` + `packer/golden`; SSH communicator; `Invoke-Phase` wrapper; phases de-rebooted |
| T07 Terraform module | done | clone-from-template, guestinfo identity, TODO(#12)/(#13), offline mirror |
| T08 CI rewrite | done | validate→build→image-test→promote→deploy; `Test-BuildInputs`; MinIO stages dropped |
| T09 retire Be1 glue | done | removed S3/SigV4 + reboot glue + dead files; Bootstrap stubbed; Validate-NoAliases repurposed |
| T10 Git LFS + transfer | done | `.gitattributes` LFS; `transfer/Export|Import-Transfer.ps1` |
| T11 docs | done | this file + CLAUDE.md/README/ARCHITECTURE/MIGRATION-TO-TERRAFORM/BACKLOG |

## Verification done on the dev leg (no PS runtime / no air-gap)
- Every `.ps1` passes a delimiter + quote-parity static check (stand-in for `verify-ps`, which needs
  Windows PowerShell 5.1); `ps-reviewer` ran on the new/critical scripts (transfer, Phase3-Install +
  Common helpers, Register-RunnerFirstBoot) — findings fixed.
- HCL (`packer/`, `terraform/`) passed a string/comment-aware brace-balance check; `packer validate` /
  `terraform validate` + `fmt -check` are the lab-host step (tools not installed here).
- `git check-attr` confirms LFS routing; CI YAML parses.

## Post-review remediation (applied)
A deep code review found a deploy-path blocker and several gaps; all fixed on this branch:
- **B1/B2 (blocker):** first-boot couldn't find `lib/` → `Phase3-Install` now stages `lib/` +
  `validation/Invoke-FinalValidation.ps1` to `C:\GitLab-Runner`; `Register-RunnerFirstBoot` broadened its
  candidates and dot-sources the validation file (deploy-gate now actually runs).
- **B3:** runner service (SYSTEM) now `docker login`s at first boot using guestinfo registry creds, so
  runtime private-image pulls work (build-time login ran as a different user).
- **B4:** added a manual `build-base` CI job (golden clones `ws2019-base`).
- **B5:** `Test-BuildInputs` magic-byte check + `git lfs pull` in CI catch unsmudged LFS pointers.
- **B6:** base build installs OpenSSH offline from a `cd_files` zip (FoD fallback) — true offline verify
  is still a lab step.
- **B7:** Phase 1 preflight runs `-SkipRegistry` (registry gated at Phase 3 pre-pull instead).
- **B9/B10/B11:** `Invoke-Phase` honors phase markers; bounded first-boot retry raises Event Log 9015 +
  `.firstboot_failed`; `C:\provision` is removed from the golden image.
- **Logging:** `Write-Log` now emits `[component] [runid]`.
- Token rotation (taint/replace) documented in `terraform/`.

## Dev-leg verification (executed with real tooling)
Installed Terraform 1.9.8, Packer 1.11.2 (+ vsphere plugin 1.4.0), PowerShell 7.4.6, git-lfs 3.5.1 and
ran everything below GREEN (see `tests/dev-leg/`):

| Lane | Result |
|---|---|
| `terraform fmt -check` + `validate` (real vsphere 2.8.3 schema, filesystem mirror) | PASS |
| `packer fmt -check` + `validate` base + golden (real vsphere plugin) | PASS |
| `[Parser]::ParseInput` on every `.ps1` (pwsh 7) | PASS |
| `xmllint` autounattend.xml | PASS |
| `Validate-NoAliases` (0 clean / 1 on a hardcoded-host violation) | PASS |
| logic suite — 13 tests (Config resolution, Common helpers, build/deploy gates; Windows cmdlets mocked) | 13/13 |
| transfer suite — 10 tests (REAL git + git-lfs bundle/CAS round-trip + SHA-verify + tamper-reject) | 10/10 |

**Bugs the verification found and fixed** (none were caught by static checks alone):
- `terraform fmt` violations (CI would have failed); `packer` `network_adapters` block invalid on
  `vsphere-clone` (would fail `packer validate`/build); illegal `--` in autounattend XML comments;
  linux-only TF lock → regenerated cross-platform (linux+windows).
- **HIGH:** `Write-Log` emitted via `Write-Output`, so boolean helpers (`Copy-RepoFile`, `Install-Local*`,
  `Invoke-Registration`, `Test-AlreadyRegistered`) returned `[log, $bool]` arrays — always truthy —
  making `if (-not (helper))` **fail open** on errors. Fixed (→ `[Console]::WriteLine`).
- `Get-RepoPath` hardcoded `\` → now uses the platform separator.

**Still UNVERIFIED (lab-only):** `Register-RunnerFirstBoot.ps1` end-to-end (hardcoded `C:\` paths),
docker-windows containers, vSphere clone + guestinfo delivery, reboot-resume under `windows-restart`,
full `packer build` / `terraform apply`. pwsh 7 ≠ Windows PS 5.1, and Windows cmdlet behavior is mocked.

## Naming note
`Config.ps1` still uses `S3Keys` / `S3KeysExtra` / `ToolPackages[].S3Key` as field names — these are now
**repo-relative paths consumed locally** (Git LFS / uploaded tree), not MinIO keys. Kept the names to
minimise churn; a rename to `Artifacts`/`RelPath` is a clean follow-up.

## Open TODOs (block `terraform apply` only — never the Packer build)
- `# TODO(#12)` vCenter placement: server FQDN, datacenter, cluster, datastore, portgroup, svc account.
- `# TODO(#13)` domain join: target OU distinguished name + least-priv join account.

## Next manual steps (need a lab vCenter — not internet-testable)
- `packer build` of the base + golden templates; prove reboot-resume under `windows-restart`.
- Acceptance-gate: `terraform apply` one runner, self-register, run representative CI pipelines.
