# `ci/`

Internal GitLab CI helper scripts.

| Script | Purpose |
| --- | --- |
| `Validate-NoAliases.ps1` | Enforces the alias-by-resolution invariant in `lib/Config.ps1`. |
| `Publish-GoldenManifest.ps1` | Derives a release manifest from the Packer build manifest and repo `VERSION`. |
| `Invoke-AcceptanceGate.ps1` | Scaffold for future end-to-end runner acceptance tests. Currently exits non-zero by design. |

The pipeline entrypoint is `.gitlab-ci.yml`.

Expected stages:

1. `validate`
2. `plan`
3. `deploy`

The `deploy` job is manual and limited to the `terraform` branch.
