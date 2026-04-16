# validation/

Post-install validation suite.

| File | Function | Called by |
|------|----------|-----------|
| `Invoke-FinalValidation.ps1` | `Invoke-FinalValidation` | Phase 3 (step 3.12) |

Runs 17 checks against OS, Docker, Runner, Git, Defender, scheduled tasks, and disk.
Results are logged to `install.log` and to the Application Event Log (event 9010 or 9011).
