# `packer/` — golden-image build (Be1 replacement)

Packer is the build orchestrator (replaces VMware Aria "Be1"). It produces one **generic, unregistered**
WS2019 GitLab-Runner golden image; Terraform (`../terraform/`) deploys + first-boot-registers runners from it.

- `base/` — `vsphere-iso` build from ISO + `autounattend.xml` that installs **and enables OpenSSH**, so the
  **SSH communicator** connects from first boot (Packer defaults to WinRM, which is GPO-blocked at Kayhut).
- `golden/` — `vsphere-clone` from the base template → `file` provisioner uploads the repo →
  `../provisioners/Invoke-Phase.ps1 -Phase 1` → `windows-restart` → `-Phase 2` → `windows-restart` →
  `-Phase 3` (build-time `Phase3-Install`) → build-gate (`Invoke-FinalValidation`).

Air-gap: plugin versions pinned, offline `filesystem_mirror`. Validate with `packer validate` +
`packer fmt -check` (run on a host with Packer + lab-vCenter access — not the dev/internet leg).
