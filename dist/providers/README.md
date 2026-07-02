# `dist/providers/`

Offline Terraform provider mirror.

Required provider:

```text
registry.terraform.io/vmware/vra
version: 0.17.2
platform: windows_amd64
```

`terraform/terraform.rc` points Terraform at this mirror. The preflight script
fails when the mirror is absent, the provider version is wrong, or the Windows
package is missing.
