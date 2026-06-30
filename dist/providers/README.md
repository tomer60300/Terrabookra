# `dist/providers/`

Place the Terraform provider filesystem mirror here on the internal leg.

Required provider:

```text
registry.terraform.io/vmware/vra/0.17.2/...windows_amd64...
```

Generate or refresh the mirror on an internet-connected staging host, then carry
it into the air-gapped network:

```powershell
terraform.exe providers mirror dist/providers
```
