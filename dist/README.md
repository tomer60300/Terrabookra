# `dist/`

Internal-only runtime bundle for Terraform.

Expected layout:

```text
dist/
  bin/
    terraform.exe
  providers/
    registry.terraform.io/
      vmware/
        vra/
          0.17.2/
            windows_amd64/
              terraform-provider-vra_...
```

`scripts/Test-AriaTerraformPreflight.ps1` checks this layout before Terraform
plan/apply.

The public leg does not commit these binaries. Populate them on the internal leg
from the approved offline source.
