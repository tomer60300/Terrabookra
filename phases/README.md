# phases/

One file per build-time phase. Each exports a single function, invoked in order by
the Packer **golden** template through `provisioners/Invoke-Phase.ps1` — there is no
orchestrator (`Bootstrap-GitLabRunner.ps1` is a retired stub). Packer owns the reboots
(`windows-restart`) between phases; the `.phaseN_complete` markers are existence-only,
solely so a re-run skips an already-completed phase.

| File | Function | Runs |
|------|----------|------|
| `Phase1-SystemPrep.ps1` | `Invoke-Phase1` | First, on a fresh VM → Packer `windows-restart` |
| `Phase2-DockerInstall.ps1` | `Invoke-Phase2` | After the Phase 1 reboot → Packer `windows-restart` |
| `Phase3-Install.ps1` | `Invoke-Phase3Install` | After the Phase 2 reboot; installs software, writes a token-less `config.toml` skeleton, runs the build-gate |

Each phase logs numbered steps (1.1, 2.1, 3.1, …) so the install log tells you exactly
which file and step failed. All phases depend on `lib/Config.ps1` and `lib/Common.ps1`
being loaded first (done by `Invoke-Phase.ps1`).

Per-clone identity and runner registration are **not** here — they happen at first boot
via `provisioners/Register-RunnerFirstBoot.ps1` (token + hostname from vSphere guestinfo).
