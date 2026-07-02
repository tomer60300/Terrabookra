# `tools/`

Offline tool packages consumed by Phase 1 and Phase 3.

`lib/Config.ps1` is the inventory source of truth. The files here are expected to
be present as Git LFS artifacts on the internal leg.

Important groups:

- `openssh/`: portable OpenSSH server zip and optional authorized keys.
- `observability/`: windows_exporter MSI and blackbox_exporter zip.
- package folders for the tools listed in `Config.ToolPackages`.
- OpenCode/WebView2 installer and machine config inputs.

Run this after importing the transfer bundle:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File validation\Test-BuildInputs.ps1 -SkipRegistry
```

That catches missing or unsmudged LFS files before Packer starts installing them.
