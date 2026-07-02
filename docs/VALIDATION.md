# Validation

Validation is layered. The goal is to fail early on source issues, fail during
Packer when the image is not shippable, and fail on first boot when a clone is
not an operational runner.

## CI validate stage

`.gitlab-ci.yml` runs:

1. `.claude\verify-ps.ps1` over every `.ps1` file.
2. `ci\Validate-NoAliases.ps1`.
3. `scripts\Test-AriaTerraformPreflight.ps1 -SkipAriaApi`.
4. `terraform init -backend=false`.
5. `terraform validate`.

`verify-ps.ps1` imports PSScriptAnalyzer unconditionally, so the CI image must
already contain the module.

## Terraform preflight

`scripts/Test-AriaTerraformPreflight.ps1` checks:

- exact Terraform version `1.0.5`.
- offline provider mirror for `vmware/vra` `0.17.2`.
- `TF_CLI_CONFIG_FILE`.
- `.terraform.lock.hcl`.
- refresh token discipline.
- no direct `hashicorp/vsphere`, `vsphere_`, or `vcenter` use in Terraform code.
- no post-Terraform-1.0 syntax such as `optional(...)`.
- `vm_inputs` values are quoted strings.
- Aria reachability and token validation, unless `-SkipAriaApi` is used.

## Build-input validation

`validation/Test-BuildInputs.ps1` checks that repo-relative artifact paths from
`Config.ps1` exist and are not Git LFS pointer files.

Phase 1 runs it with `-SkipRegistry`; Phase 3 performs the real image pull gate.

## Build-gate

`validation/Invoke-FinalValidation.ps1` verifies image correctness before Packer
can publish the golden template. It checks:

- WS2019 build.
- Containers feature.
- Hyper-V installed or explicitly skipped.
- Docker service, Docker version, and process isolation.
- runner binary validity.
- VMware Tools presence.
- Git and machine environment setup.
- Defender exclusions.
- helper image presence.
- Docker metrics in daemon config.
- power plan and long paths.
- disk space.
- tool inventory.
- WebView2 and OpenCode config.

The build-gate intentionally does not require the runner service, because the
golden image is unregistered.

## Deploy-gate

`Test-RunnerRegistered` runs after first-boot registration. It checks:

- `gitlab-runner` service running.
- `gitlab-runner verify` reports alive.
- all required scheduled tasks exist.
- Health-Check task execution limit is two hours.
- SSH service is running.
- windows_exporter and blackbox_exporter are running.
- runner metrics firewall rule exists.

The first-boot marker is written only after the deploy-gate passes.

## Local checks used during docs/source work

Useful source-only checks:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "$bad=0; Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object { & .claude\verify-ps.ps1 -Path $_.FullName; if ($LASTEXITCODE -ne 0) { $bad++ } }; if ($bad) { exit 1 }"
powershell -NoProfile -ExecutionPolicy Bypass -File ci\Validate-NoAliases.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-AriaTerraformPreflight.ps1 -SkipAriaApi
```

The full Packer build, first-boot behavior, and Terraform apply require the
internal lab/live services.
