# binaries/

Build binaries, tracked via Git LFS (see `.gitattributes`) and carried to the air-gapped leg
via the USB transfer (`transfer/Export-Transfer.ps1`). Absent (pointer-only) on the public dev leg.

| File | Version | Purpose |
|------|---------|---------|
| `gitlab-runner-16.7.0-windows-amd64.exe` | 16.7.0 | GitLab Runner binary |
| `docker/docker.exe` | 25.0.5 | Docker CLI |
| `docker/dockerd.exe` | 25.0.5 | Docker daemon |
| `git/MinGit-2.43.0-64-bit.zip` | 2.43.0 | Minimal Git for Windows (no installer, no GUI) |

These are raw binaries extracted from the official Docker zip — not a Mirantis Container Runtime installer.
