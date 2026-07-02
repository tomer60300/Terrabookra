# `phases/`

Build-time provisioning phases run by Packer through
`provisioners/Invoke-Phase.ps1`.

| File | Function | When it runs |
| --- | --- | --- |
| `Phase1-SystemPrep.ps1` | `Invoke-Phase1` | First golden build step, before Packer restart. |
| `Phase2-DockerInstall.ps1` | `Invoke-Phase2` | After Phase 1 restart. |
| `Phase3-Install.ps1` | `Invoke-Phase3Install` | After Phase 2 restart. |

Packer owns reboot sequencing with `windows-restart`. The phases do not use the
old Be1 `3010` reboot contract.

Phase 3 writes only a token-less runner config skeleton. Final runner
registration happens on deployed clones through
`provisioners/Register-RunnerFirstBoot.ps1`.
