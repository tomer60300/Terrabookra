# `provisioners/` — in-guest entry points

Scripts Packer/Terraform invoke inside the guest. They dot-source `lib/Config.ps1` + `lib/Common.ps1`.

- `Invoke-Phase.ps1 -Phase <1|2|3>` — thin Packer entry: dot-sources Config + Common + the requested
  phase file and calls `Invoke-PhaseN`, then exits 0. Packer owns sequencing and the `windows-restart`
  between phases (the phases no longer self-reboot or self-chain).
- `Register-RunnerFirstBoot.ps1` — runs once at first boot from a SYSTEM startup scheduled task. Reads the
  runner token + hostname from `guestinfo` (fallback env/file), writes the final `config.toml`, registers
  if the token is a PAT/registration token, installs + starts the runner service. Idempotent + retry.
