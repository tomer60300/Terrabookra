# `dist/bin/`

Place the approved Windows Terraform binary here on the internal leg:

```text
dist/bin/terraform.exe
```

Required version: `1.0.5`.

The GitLab CI pipeline invokes this exact path through the `TERRAFORM_EXE`
variable.
