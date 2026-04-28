# Fleet Management Scripts

These scripts run from your **admin PC**, NOT on the runners. They use **OpenSSH** (the runners' `sshd`, enabled by `scripts/Enable-RemoteSSH.ps1`). The previous versions used WinRM PSRemoting; that transport is blocked by domain GPO at Kayhut, so we switched to SSH.

## Auth model

Same as a manual `ssh runner-NN` from your PC. Three flavours, in order of operational comfort:

1. **SSH key auth (recommended for fleet ops).** One key, dropped into `C:\ProgramData\ssh\administrators_authorized_keys` on every runner during provisioning. Pass `-PrivateKey $HOME\.ssh\id_ed25519` to the scripts. No prompts, fan-out works at scale.
2. **AD password auth (good for ad-hoc).** Domain-joined runners hand password attempts to the Windows logon stack which validates against the DC. The scripts fall back to this if no key is found, but `ssh` will prompt for a password **per host** -- painful for fleets larger than a handful.
3. **GSSAPI/Kerberos (passwordless on a domain-joined admin PC).** Pass `-KerberosAuth`. Requires the runner's `sshd_config` to set `GSSAPIAuthentication yes` (off by default) and a registered SPN. Worth setting up if your team is fully domain-joined.

## Scripts

| Script | Purpose |
|---|---|
| `Get-FleetHealth.ps1` | Query all runners, display health dashboard table (services, disk, version, exporters) |
| `Invoke-FleetCommand.ps1` | Execute any PowerShell command across all runners in parallel |

## Quick start

```powershell
# Health dashboard with SSH key auth (recommended)
.\fleet\Get-FleetHealth.ps1 `
    -Runners runner01,runner02,runner03 `
    -PrivateKey $HOME\.ssh\id_ed25519

# Restart Docker everywhere
.\fleet\Invoke-FleetCommand.ps1 `
    -Runners runner01,runner02 `
    -Command 'Restart-Service docker -Force' `
    -PrivateKey $HOME\.ssh\id_ed25519

# Collect log bundles from all runners
.\fleet\Invoke-FleetCommand.ps1 `
    -Runners runner01,runner02 `
    -Command 'C:\GitLab-Runner\scripts\Export-RunnerLogs.ps1' `
    -PrivateKey $HOME\.ssh\id_ed25519

# Check golden image versions (works fine with AD password too -- just slow)
.\fleet\Invoke-FleetCommand.ps1 `
    -Runners runner01,runner02 `
    -Command 'Get-Content C:\GitLab-Runner\.golden-version'

# Same fan-out, with explicit AD username
.\fleet\Invoke-FleetCommand.ps1 `
    -Runners runner01,runner02 `
    -SshUser KAYHUT\store `
    -Command 'hostname'
```

## Tips

- Store runner hostnames in a `runners.txt` file and use `(Get-Content .\runners.txt)` as the `-Runners` parameter.
- First connection to a host adds its key to `~/.ssh/fleet_known_hosts` (separate from your default `known_hosts` so fleet ops don't pollute it).
- Use `-ExportCsv fleet-status.csv` on `Get-FleetHealth` to save results.
- For ad-hoc one-off queries, plain `ssh runner01 powershell -Command 'docker ps'` works just as well -- the fleet scripts add parallelism + structured output, not magic.

## Requirements on the admin PC

- `ssh.exe` on `PATH`. Windows 10/11 and Server 2019+ have OpenSSH client by default; otherwise install via `Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0` or use Git for Windows' bundled `ssh`.
- Network reachability to runner TCP 22.
- A keypair at `~/.ssh/id_ed25519` (or wherever `-PrivateKey` points). Generate with `ssh-keygen -t ed25519`.

## Switching from WinRM to SSH

If you've been using the older WinRM-based fleet scripts, the practical changes:

| Then (WinRM) | Now (SSH) |
|---|---|
| Required `Enable-RemotePowerShell.ps1` on runners | Requires `Enable-RemoteSSH.ps1` on runners (Phase 1 step 1.11 already does this) |
| TCP 5985/5986 inbound | TCP 22 inbound |
| `-Credential (Get-Credential)` | `-PrivateKey <path>` (or just AD password prompt) |
| `Invoke-Command -ComputerName` (PSRemoting) | `ssh host powershell -EncodedCommand <b64>` (script encodes for you) |
| Returned PowerShell objects directly | Probe emits JSON; admin script parses |
| Failed when WinRM service was GPO-locked | Works because sshd isn't subject to that GPO |
