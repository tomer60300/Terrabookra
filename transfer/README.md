# `transfer/`

Air-gap handoff scripts.

| Script | Direction | Purpose |
| --- | --- | --- |
| `Export-Transfer.ps1` | source leg to USB | Creates a git bundle, copies the Git LFS CAS, writes a manifest, and tags the handoff. |
| `Import-Transfer.ps1` | USB to internal repo | Restores the LFS CAS, fetches the bundle, verifies the manifest SHA, updates the target branch, and materializes LFS files. |

Export:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File transfer\Export-Transfer.ps1 `
  -OutDir D:\transfer `
  -Ref terraform
```

Import:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File transfer\Import-Transfer.ps1 `
  -InDir D:\transfer\<id> `
  -Branch terraform
```

The transfer process moves source and LFS objects. It does not provide internal
service credentials, Terraform provider mirrors, Packer plugins, or catalog
configuration.
