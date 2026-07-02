# `tests/dev-leg/`

Source-side tests for logic that can be checked without the internal lab.

These tests are written for PowerShell 7 (`pwsh`) and mock Windows-only cmdlets
where needed. They are not a replacement for the internal Windows/Packer/Aria
pipeline.

| Script | Purpose |
| --- | --- |
| `logic-tests.ps1` | Exercises config alias resolution, common helper behavior, and validation split logic with mocks. |
| `transfer-roundtrip.ps1` | Creates a real Git/LFS test repo, exports a transfer bundle, imports it, verifies SHA and LFS materialization, and checks tamper rejection. |
| `run-all.ps1` | Runs the dev-leg test set. |

Run:

```powershell
pwsh -NoProfile -File tests\dev-leg\run-all.ps1
```

Still requires the internal lab:

- Packer base/golden build.
- WS2019 Docker process-isolation jobs.
- first-boot VMware guestinfo registration.
- Aria catalog input mapping.
- Terraform apply.
