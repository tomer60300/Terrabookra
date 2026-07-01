# Verification log — final sign-off

Env: Windows 11, PowerShell 5.1.26100, git-lfs 3.7.0, terraform 1.0.5 + packer 1.11.2 (from `dist/bin`), vsphere plugin 1.4.0, vra 0.17.2 mirror. Branch `ultracode-review` (= `origin/terraform`), fix commit `7b987ad`.

| # | Command | Expected | Actual | Status |
|---|---------|----------|--------|--------|
| 1 | `git rev-parse HEAD` | shipped commit | `7b987ad` (fixes) on `052ee52` (shipped) | PASS |
| 2 | `terraform version` | v1.0.5 | `Terraform v1.0.5` | PASS |
| 3 | `terraform fmt -check -recursive .` | exit 0 | exit 0 (after fmt-normalizing `example.tfvars`) | PASS |
| 4 | `terraform init -backend=false` | providers resolve | ok (vra 0.17.2) | PASS |
| 5 | `terraform validate` | valid | `Success! The configuration is valid.` | PASS |
| 6 | offline `init` via `terraform.rc` mirror (`-chdir=terraform`) | installs vra from `dist/providers` | `Installed vmware/vra v0.17.2` from mirror | PASS |
| 7 | `terraform providers lock -platform=windows_amd64` | lock covers win | no change — already covered | PASS |
| 8 | `packer fmt -check -recursive packer` | exit 0 | exit 0 | PASS |
| 9 | `packer validate packer/base` (+ vsphere 1.4.0 plugin) | parses/plugin resolves | parses + plugin OK; only error = dev-leg-absent OpenSSH LFS binary | PASS (env gap) |
| 10 | `verify-ps` on the 3 changed files + all edited `.ps1` this session | 0 parse/Error | clean | PASS |
| 11 | `ci/Validate-NoAliases.ps1` | exit 0 PASSED | `PASSED: alias-by-resolution invariant holds` | PASS |
| 12 | PS5.1 empirical: `& missing.exe 2>&1` under `EAP=Continue` | (refute PS-BOOT-002) | **THROWS CommandNotFoundException** (both plain + pipeline form) — no fail-open | PASS (finding refuted) |
| 13 | grep: any VMware Tools install in repo | (verify PKR-BASE-002) | none found; `vmtoolsd` only *consumed* by `Get-GuestInfo` | CONFIRMED gap → guard added + open-item |
| 14 | `tests/dev-leg/transfer-roundtrip.ps1` (earlier) | bundle+CAS round-trip | 10/0; real package import materialized binaries as PE | PASS |
| 15 | Codex round-2 (post-fix) | PASS / no new bug | **PASS** — no new bug, no remaining blocker/high | PASS |

## UNVERIFIED — require the lab vCenter / live Aria (cannot run on the dev leg)
- `packer build` end-to-end (base + golden), reboot-resume under `windows-restart`, OpenSSH first-connect — **UNVERIFIED** (no vCenter/ISO here).
- First-boot on a real clone: `vmtoolsd` guestinfo read, E: disk-init + data-root move, `gitlab-runner register`, service start — **UNVERIFIED** (no WS2019 clone).
- `vm_inputs` string→catalog-schema coercion by vra 0.17.2 — **UNVERIFIED** (needs the real Aria catalog item schema).
- `terraform apply` against live Aria — **UNVERIFIED** (air-gapped Aria unreachable).

## N/A
- Nightly/overnight review system (`tools/nightly-review/*`, `install-linux-cron.sh`) — **NOT PRESENT** in this repo; out of scope, not built (building it would be over-engineering beyond the delivery plan).
