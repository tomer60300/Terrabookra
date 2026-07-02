# `validation/`

Validation scripts shared by CI, Packer, and first boot.

| Script | Purpose |
| --- | --- |
| `Test-BuildInputs.ps1` | Checks repo-relative artifacts from `Config.ps1` and detects unsmudged Git LFS pointer files. Can also probe GitLab and registry reachability. |
| `Invoke-FinalValidation.ps1` | Provides the build-gate (`Invoke-FinalValidation`) and deploy-gate (`Test-RunnerRegistered`). |

Build-gate:

- runs during Phase 3 of the Packer golden build.
- checks image correctness.
- does not require runner registration.

Deploy-gate:

- runs during first boot after registration.
- checks runner service, runner verify, scheduled tasks, SSH, exporters, and firewall.
- controls whether `.firstboot_complete` is written.
