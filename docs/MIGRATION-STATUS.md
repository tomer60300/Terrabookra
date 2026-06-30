# Migration status - infra_tf Aria catalog deployment

`main` remains the Be1 rollback baseline. The `terraform` branch deploy target is now the
infra_tf-compatible Aria catalog path:

- Terraform runtime: `dist/bin/terraform.exe`, exactly `1.0.5`.
- Provider: `vmware/vra` exactly `0.17.2`.
- Provider install: offline filesystem mirror at `dist/providers/`, selected by `TF_CLI_CONFIG_FILE`.
- Provisioning API: Aria Service Broker catalog item through `vra_deployment`.
- Secret path: `TF_VAR_vra_refresh_token` only.
- Inputs: `vm_inputs` is `map(string)`; quote numeric and boolean-looking values.

## Current status

| Area | Status | Notes |
|---|---|---|
| Aria deploy module | done | `module/aria-vm` resolves `data.vra_project`, `data.vra_catalog_item`, and requests `vra_deployment`. |
| Terraform root | done | `terraform/` is VRA-only and Terraform 1.0.5-compatible. No vSphere provider or vCenter variables. |
| Provider lock | done | `.terraform.lock.hcl` regenerated for `registry.terraform.io/vmware/vra` `0.17.2` with multi-platform hashes. |
| Offline runtime docs | done | `dist/` placeholder READMEs document the required internal `terraform.exe` and provider mirror layout. |
| Preflight | done | `scripts/Test-AriaTerraformPreflight.ps1` checks runtime, mirror, token source, lock file, Terraform syntax drift, `vm_inputs`, backend syntax, and Aria API reachability/auth. |
| CI | done | `.gitlab-ci.yml` uses validate/plan/deploy with `dist/bin/terraform.exe`, `TF_CLI_CONFIG_FILE`, and preflight. |
| Firstboot gate | done | `Register-RunnerFirstBoot.ps1` no longer marks first boot complete when `Test-RunnerRegistered` fails or is missing. |
| Historical Packer work | retained | Packer/vSphere files remain as spike history but are not the runner deploy CI path. |

## Verified on dev leg

- `terraform init -backend=false` with Terraform `1.0.5`: PASS.
- `terraform validate` with Terraform `1.0.5`: PASS.
- `terraform fmt -check -recursive`: PASS.
- `terraform providers lock` after init for `windows_amd64`, `linux_amd64`, `linux_arm64`: PASS.
- `verify-ps` on `scripts/Test-AriaTerraformPreflight.ps1`: PASS.
- `verify-ps` on `provisioners/Register-RunnerFirstBoot.ps1`: PASS.
- Positive preflight dry-run with a temp Terraform binary, fake mirror, dummy token, and `-SkipAriaApi`: PASS.
- Expected local preflight against the real worktree: FAILS early because `dist/bin/terraform.exe`,
  `dist/providers`, and the production refresh token are not present on the dev leg.

## Still unverified

- Aria URL reachability from the production network.
- Refresh-token validation against the real Aria endpoint.
- Project/catalog item/version/entitlement resolution.
- Real Service Broker catalog item input names.
- Full `terraform plan` and `terraform apply`.
- VM readiness after Aria deploy: PowerShell 5.1, WS2019 build, Docker daemon, Windows container image,
  `gitlab-runner verify`, Docker pipe, and GitLab connectivity.

## Production blockers

1. Stage `dist/bin/terraform.exe` `1.0.5`.
2. Stage `dist/providers/` with `vmware/vra` `0.17.2`, especially `windows_amd64`.
3. Set `TF_CLI_CONFIG_FILE` to `terraform/terraform.rc`.
4. Set `TF_VAR_vra_refresh_token` as a masked/protected process or CI variable.
5. Replace `terraform/example.tfvars` values with the real internal project, catalog item, version,
   deployment name, and exact `vm_inputs` keys.
6. Run `scripts/Test-AriaTerraformPreflight.ps1` without `-SkipAriaApi` inside the production network.
