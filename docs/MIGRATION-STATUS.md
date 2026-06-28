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
