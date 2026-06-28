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
| Setup (branch/default/.gitignore) | partial | branch + .gitignore done locally; remote push + default-branch flip blocked (session credential read-only / 403) — operator completes from their terminal |
| T01 scaffold + this doc | done | `packer/ terraform/ provisioners/ transfer/` created |
| T02 Config env-aliases + retire Harbor | pending | |
| T03 Phase3-Install split + artifact rewire | pending | |
| T04 first-boot registration | pending | |
| T05 validation split | pending | |
| T06 Packer templates | pending | |
| T07 Terraform module | pending | |
| T08 CI rewrite | pending | |
| T09 retire Be1 glue | pending | |
| T10 Git LFS + transfer | pending | |
| T11 docs | pending | |

## Open TODOs (block `terraform apply` only — never the Packer build)
- `# TODO(#12)` vCenter placement: server FQDN, datacenter, cluster, datastore, portgroup, svc account.
- `# TODO(#13)` domain join: target OU distinguished name + least-priv join account.

## Next manual steps (need a lab vCenter — not internet-testable)
- `packer build` of the base + golden templates; prove reboot-resume under `windows-restart`.
- Acceptance-gate: `terraform apply` one runner, self-register, run representative CI pipelines.
