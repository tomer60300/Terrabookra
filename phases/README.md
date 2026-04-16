# phases/

One file per installation phase. Each exports a single function (`Invoke-PhaseN`) called by the orchestrator.

| File | Function | Triggers |
|------|----------|----------|
| `Phase1-SystemPrep.ps1` | `Invoke-Phase1` | No markers found (fresh VM) |
| `Phase2-DockerInstall.ps1` | `Invoke-Phase2` | `.phase1_complete` marker exists |
| `Phase3-RunnerSetup.ps1` | `Invoke-Phase3` | `.phase2_complete` marker exists |

Each phase logs numbered steps (1.1, 2.1, 3.1, etc.) so the install log tells you exactly which file and step failed.

All phases depend on `lib/Config.ps1` and `lib/Common.ps1` being loaded first.
