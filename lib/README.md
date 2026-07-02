# `lib/`

Shared PowerShell loaded by Packer phases, first boot, and validation.

| File | Purpose |
| --- | --- |
| `Config.ps1` | Source of truth for runner defaults, aliases, paths, package inventory, images, metrics ports, and phase markers. |
| `Common.ps1` | Logging, repo-relative artifact copy helpers, PE/archive validation, service waits, DNS helper, and durable phase markers. |

Notes:

- `S3Keys` and `S3KeysExtra` are historical names. Their values are
  repo-relative paths in the Terraform branch.
- Logging uses `[Console]::WriteLine` so helper functions can safely return
  booleans without log text contaminating the success stream.
- Phase markers are durable completion markers and do not expire.
