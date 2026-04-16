# lib/

Shared libraries dot-sourced by `Install-GitLabRunner.ps1` before any phase runs.

| File | Purpose |
|------|---------|
| `Config.ps1` | All settings, paths, S3 keys, thresholds, constants. **Edit this file to change configuration.** |
| `Common.ps1` | TLS bypass, logging (`Write-Log`), S3 download (`Get-S3Object`), PE validation, phase markers, Be1 reboot, service helpers |

**Load order matters:** `Config.ps1` must be loaded before `Common.ps1` because Common reads `$Script:Config`.
