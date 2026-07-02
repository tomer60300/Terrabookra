# `provisioners/`

Entrypoints used by Packer and by deployed runner clones.

| File | Purpose |
| --- | --- |
| `Invoke-Phase.ps1` | Thin Packer entrypoint. Loads `Config.ps1` and `Common.ps1`, skips completed phases, then calls the selected phase function. |
| `Register-RunnerFirstBoot.ps1` | Runs on deployed clones at startup. Reads clone identity, prepares the data drive, writes final `config.toml`, installs the runner service, logs into the registry as SYSTEM, and runs the deploy-gate. |

First-boot identity lookup order:

1. VMware guestinfo through `vmtoolsd.exe`.
2. `GUESTINFO_<KEY>` machine/process environment variable.
3. `C:\GitLab-Runner\firstboot.json`.

Required key: `runner_token`.

Optional keys: `runner_hostname`, `registry_user`, `registry_pass`.
