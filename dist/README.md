# `dist/` runtime bundle

The internal leg must stage the offline Terraform runtime here before any runner
deployment:

- `dist/bin/terraform.exe` - Terraform `1.0.5`, `windows_amd64`.
- `dist/providers/` - Terraform filesystem mirror containing `vmware/vra`
  `0.17.2`, especially the `windows_amd64` package.

These binaries are not committed to the public leg. `scripts/Test-AriaTerraformPreflight.ps1`
fails early if they are missing.
