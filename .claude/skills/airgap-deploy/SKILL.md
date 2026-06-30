---
name: airgap-deploy
description: Use when operating the Terrabookra/Runners-Infra runner deployment INSIDE the air-gapped Kayhut network — importing the USB transfer, filling real values, building the golden image with Packer, and deploying GitLab Windows runners through VMware Aria with Terraform. Encodes the air-gap operator's role, required inputs, exact run order, Aria prerequisites, and the lab smoke-test gates.
---

# Air-gap deploy — in-network operator playbook

You are running **inside the air-gapped Kayhut network** (the production leg). There is **no internet**.
Everything you need arrived over **USB** from the internet leg. Your job: import it, fill the real
values, build the golden image, and deploy runners through **VMware Aria** with Terraform 1.0.5.

## Non-negotiables (do not violate)
- **No internet, ever.** No `terraform init` from the registry, no `packer init` from GitHub, no
  tool downloads. Providers/plugins come from the offline mirror in `dist/`; binaries from Git LFS /
  the USB bundle; container images from the GitLab Container Registry.
- **PowerShell 5.1 only** on the WS2019 guests (no PS7 syntax/cmdlets).
- **Aria only — never talk to vCenter directly.** Deploy via the Service Broker catalog item
  (`vra_deployment`); the catalog blueprint owns VM placement, disk, and domain-join.
- **SSH is the control plane** (WinRM is GPO-blocked). Packer uses the SSH communicator.
- **Secrets are injected, never committed/logged.** The Aria CSP refresh token is passed ONLY via
  `TF_VAR_vra_refresh_token` (env/CI-masked) — never in tfvars, CLI args, logs, or state.
- **Aliases resolve, they are not rewritten.** Code keeps the `*.kayhut.com` aliases; the internal
  leg maps them via hosts/DNS, or overrides per host with `$env:REAL_*`. `Validate-NoAliases.ps1`
  guards the invariant.

## What arrived on the USB (from `transfer/Export-Transfer.ps1`)
- A **git bundle** (code) + the **LFS content-addressable store** (the real binaries) + a manifest.
- A staged **`dist/` runtime**: `dist/bin/terraform.exe` (1.0.5) + `dist/bin/packer.exe` + the
  offline **provider mirror** `dist/providers/` (vmware/vra 0.17.2 windows_amd64) + the **packer
  plugin** `dist/packer-plugins/` (vsphere 1.4.0).
- The build binaries to drop into `binaries/` + `tools/` (docker 25.0.5, gitlab-runner 16.7.0,
  MinGit 2.43.0, OpenSSH-Win64.zip, windows_exporter, blackbox_exporter, WebView2, operator tools).

## Step 0 — Import the transfer
```powershell
.\transfer\Import-Transfer.ps1 -InDir <usb>\<transfer-id>     # restores code + LFS CAS into the repo
git lfs checkout                                              # materialize the binaries from the CAS
.\validation\Test-BuildInputs.ps1                            # confirms binaries are REAL, not LFS pointers
```
If `Test-BuildInputs` flags unsmudged pointers, the LFS CAS didn't restore — fix that before building.

## Step 1 — Fill the real values (the ONLY things you must supply)
| What | Where | Notes |
|------|-------|-------|
| Aria CSP refresh token | `$env:TF_VAR_vra_refresh_token` (or CI masked var) | **env only** — never a file |
| Aria URL | `vra_url` in a gitignored `*.auto.tfvars`, or `$env:TF_VAR_vra_url` | the Aria/Be1 endpoint |
| `vra_insecure` | tfvars | `true` only for an approved self-signed Aria cert |
| Aria project / catalog item / version | `project_name`, `catalog_item_name`, `catalog_item_version` | must already exist in Aria |
| `vm_inputs` | tfvars `map(string)` | **every value quoted**, keys = the catalog item's real input names |
| Host resolution | hosts file / internal DNS, or `$env:REAL_*` | so `*.kayhut.com` aliases resolve |
| Registry creds (per-clone) | Aria guestinfo `registry_user`/`registry_pass` | for runtime private-image pulls |
| Runner token (per-clone) | Aria guestinfo `runner_token` (+ `runner_hostname`) | glrt-* auth token preferred |

## Step 2 — Build the golden image (Packer, on the build host)
```powershell
$env:PACKER_PLUGIN_PATH = "$PWD\dist\packer-plugins"
.\dist\bin\packer.exe init   packer\base                       # no-op offline (plugin pre-staged)
.\dist\bin\packer.exe validate -var-file=packer\base\<your>.pkrvars.hcl  packer\base
.\dist\bin\packer.exe build    -var-file=packer\base\<your>.pkrvars.hcl  packer\base    # -> base template
.\dist\bin\packer.exe build    -var-file=packer\golden\<your>.pkrvars.hcl packer\golden # -> golden, runs build-gate
```
The golden build runs Phase1 → `windows-restart` → Phase2 → `windows-restart` → Phase3-Install →
`Invoke-FinalValidation` (build-gate). It produces a **generic, UNREGISTERED** image. Set
`repo_root` (golden pkrvars) to the absolute repo path; provide least-priv vCenter creds for the
Packer SSH build (separate from the Aria deploy path).

## Step 3 — Deploy runners (Terraform via Aria)
```powershell
$env:TF_CLI_CONFIG_FILE = (Resolve-Path .\terraform\terraform.rc).Path
$env:TF_VAR_vra_refresh_token = '<refresh token, process env only>'
.\scripts\Test-AriaTerraformPreflight.ps1 -RequiredVmInputKeys <keys>   # boring-failure gate
.\dist\bin\terraform.exe -chdir=terraform init     # OFFLINE via the dist mirror (always use -chdir)
.\dist\bin\terraform.exe -chdir=terraform validate
.\dist\bin\terraform.exe -chdir=terraform plan -out=tfplan   # stops here until Aria objects exist
.\dist\bin\terraform.exe -chdir=terraform apply tfplan       # manual gate
```
At first boot each clone runs `Register-RunnerFirstBoot.ps1` (SYSTEM startup task): reads the
guestinfo token+hostname, **initializes the E: data disk + moves docker's data-root onto it**,
writes the final `config.toml`, registers, and starts the runner — idempotent.

## Aria objects that must already exist (plan/apply fails loudly otherwise)
project (`project_name`) · Service Broker catalog item + version · an entitlement for the token
principal · the backing cloud template with image/flavor/network mappings · project quota/lease.
The catalog blueprint owns **VM placement + data disk + domain-join** (not Terraform).

## Verification gates — do not call it done without these
- `Validate-NoAliases.ps1` green · `verify-ps` clean on changed `.ps1`.
- `terraform validate` + `packer validate` pass (validated clean on the internet leg already).
- **Lab smoke-test BEFORE fleet rollout** (these are UNVERIFIED until run on real WS2019):
  the Packer golden build (reboot-resume + OpenSSH first-boot), and `Register-RunnerFirstBoot`
  (data-disk init, registration, `gitlab-runner verify`) on one clone.

## Known gotchas (decided on the internet leg)
- **`vm_inputs` are all strings**; the catalog request relies on Aria coercing `"24"`/`"true"` to
  the blueprint's typed inputs. **Confirm the catalog item's input schema with its owner** — this is
  the one thing not provable off the live catalog.
- **docker is 25.0.5** (the `25.0.15` in `binaries/README.md` is a typo; 25.0.x has no `.15`).
- **Local Administrator password** (`autounattend.xml`) is build-only + not rotated per clone
  (SEC-01) — documented, intentionally not auto-reset; rely on domain/SSH-key access.
- Convenience tools that may be missing from the USB (non-fatal — `Install-Tools` tolerates it):
  SystemInformer, BareTail, WizTree, EventLook, OpenCode-desktop. Fetch + add to `tools/` if needed.
- `git`, `terraform`, `packer` always run via the **bundled `dist/bin`** exes + offline mirror —
  never a system/internet copy.
