# Configuration

Configuration is intentionally split by lifecycle stage. Do not hardcode real
internal names in source. Use aliases, CI variables, Packer variables, Terraform
variables, or first-boot guestinfo depending on when the value is needed.

## Configuration owners

| Stage | Owner | File or input |
| --- | --- | --- |
| Shared runner defaults | PowerShell config | `lib/Config.ps1` |
| Build placement and credentials | Packer variables | `packer/base/*.pkr.hcl`, `packer/golden/*.pkr.hcl` |
| Aria deployment request | Terraform variables | `terraform/*.tf`, internal `*.auto.tfvars` |
| Clone identity | Aria guestinfo/env/json | `runner_token`, `runner_hostname`, optional registry creds |
| CI runtime | GitLab CI variables | `.gitlab-ci.yml`, masked/protected variables |

## Alias model

The public repo keeps alias hostnames in source. The internal leg resolves them
through DNS/hosts or overrides them through `REAL_*` environment variables.

| Source default | Override |
| --- | --- |
| `gitlab.kayhut.com` | `REAL_GITLAB_HOST` |
| `${REAL_GITLAB_HOST}:5050` or `gitlab.kayhut.com:5050` | `REAL_GITLAB_REGISTRY` |
| `golden-image` | `REAL_REGISTRY_PROJECT` |
| `artifactory-prod` | `REAL_ARTIFACTORY_HOST` |

`ci/Validate-NoAliases.ps1` enforces that aliases remain wrapped by `REAL_*`
overrides. It does not fail because aliases exist.

## `lib/Config.ps1`

`Config.ps1` owns values consumed by the PowerShell phases and runtime scripts:

- GitLab URL and registry defaults.
- registry project and pre-pull image list.
- Docker paths, daemon path, and runner paths.
- runner tuning rendered into `config.toml`.
- scheduled task script paths.
- tool and observability package inventories.
- monitor hosts and metrics ports.
- durable phase and first-boot marker locations.

The `S3Keys` and `S3KeysExtra` names are historical. In this branch they are
repo-relative artifact paths copied from the Packer-uploaded repo tree.

## Docker daemon policy

`Phase2-DockerInstall.ps1` writes the daemon configuration. The current policy is:

- `insecure-registries` from `Config.InsecureRegistries`.
- `json-file` logging with size and file count limits.
- `data-root` from `Config.DockerDataRoot`.
- `group = docker-users`; the phase creates the group first.
- Docker metrics on `0.0.0.0:<DockerMetricsPort>`.
- `experimental = true` for Docker metrics.

The daemon intentionally does not set:

- `storage-driver`
- `dns`
- `dns-search`
- `exec-opts`

Those are either unsupported or redundant for the target Windows Server 2019
process-isolation estate.

## Packer variables

Base image variables configure vCenter placement, ISO paths, VM hardware, and the
temporary SSH communicator account.

Golden image variables configure:

- base template name.
- repo root uploaded to `C:\provision`.
- optional GitLab registry credentials for build-time pre-pulls.
- optional `REAL_GITLAB_HOST` and `REAL_GITLAB_REGISTRY` values.
- CPU and memory for the golden build VM.

Registry credentials are used by Packer provisioners for build-time pulls. They
are not intended to remain baked into the deployed runner identity.

## Terraform variables

Terraform is deploy-only. It requires:

- `vra_url`
- `vra_refresh_token`, supplied only as `TF_VAR_vra_refresh_token`
- `vra_insecure`
- `project_name`
- `catalog_item_name`
- `catalog_item_version`
- `deployment_name`
- `deployment_reason`
- `vm_inputs`

`vm_inputs` is `map(string)` by design. Every value in tfvars should be quoted,
including booleans and numbers. The Aria catalog schema performs the final type
conversion.

## First-boot identity

`Register-RunnerFirstBoot.ps1` reads each value in this order:

1. VMware Tools guestinfo: `guestinfo.<key>`.
2. Machine/process environment variable: `GUESTINFO_<KEY>`.
3. JSON fallback: `C:\GitLab-Runner\firstboot.json`.

Required:

- `runner_token`: `glrt-*` auth token, PAT, or legacy registration token.

Optional:

- `runner_hostname`: defaults to `$env:COMPUTERNAME`.
- `registry_user`
- `registry_pass`

For production, prefer pre-created `glrt-*` runner auth tokens when possible.
The PAT/registration-token path is supported but depends on GitLab returning a
new auth token during first boot.
