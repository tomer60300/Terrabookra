# Dependencies

This inventory is for the current Terraform branch. It lists what must exist on
the internal leg before validation, build, or deploy can pass.

## Tooling

| Dependency | Version or expectation | Used by |
| --- | --- | --- |
| Windows PowerShell | 5.1 | All production scripts. |
| PSScriptAnalyzer | Preinstalled on CI runner image | `.claude/verify-ps.ps1`. |
| Git | Internal checkout and transfer import/export | `transfer/*.ps1`. |
| Git LFS | Internal binary materialization | `.gitattributes`, `validation/Test-BuildInputs.ps1`. |
| Packer | Internal build host | `packer/base`, `packer/golden`. |
| Packer vSphere plugin | `github.com/hashicorp/vsphere` `1.4.0` | base/golden builds. |
| Terraform | `1.0.5`, `windows_amd64` | `terraform/`. |
| Terraform provider | `vmware/vra` `0.17.2`, `windows_amd64` | `module/aria-vm`. |

## Runtime binaries in `binaries/`

| Path | Expected content |
| --- | --- |
| `binaries/gitlab-runner-16.7.0-windows-amd64.exe` | GitLab Runner binary. |
| `binaries/docker/docker.exe` | Docker CLI. |
| `binaries/docker/dockerd.exe` | Docker daemon. |
| `binaries/git/MinGit.zip` | Offline MinGit archive. |

These files are Git LFS artifacts on the internal leg.

## Tool packages in `tools/`

`lib/Config.ps1` is the source of truth for the tool inventory. Packages include:

- OpenSSH portable zip.
- Windows Terminal dependencies.
- WebView2 runtime.
- OpenCode installer and machine config.
- NSSM.
- Sysinternals.
- WinRAR.
- Notepad++.
- WinMerge.
- BareTail.
- Klogg.
- Everything.
- WizTree.
- System Informer.
- EventLook.
- Wireshark.
- Chrome.
- windows_exporter.
- blackbox_exporter.

Run `validation\Test-BuildInputs.ps1 -SkipRegistry` after transfer import to catch
missing or unsmudged LFS inputs before Packer starts.

## Container images

`Config.PrePullImages` currently expects these images in the GitLab Container
Registry namespace:

- `gitlab-runner-helper:x86_64-v16.7.0-servercore1809`
- `servercore:ltsc2019`
- `windows:ltsc2019`

Phase 3 treats pre-pull failures as fatal because these are hard dependencies in
the air-gapped runtime.

## Internal services

| Service | Requirement |
| --- | --- |
| GitLab | HTTPS reachable from build VMs and deployed runners. |
| GitLab Container Registry | Reachable by Docker from build VMs and deployed runners. |
| VMware vCenter | Reachable by Packer build host. |
| VMware Aria Automation/Service Broker | Reachable by Terraform CI runner. |
| DNS or hosts mapping | Must resolve alias names or `REAL_*` override targets. |

## Certificates

Certificates listed in `Config.S3Certs` are repo-relative paths despite the
historical name. Phase 1 stages and imports them into Local Machine Trusted Root.

The Docker registry is also listed in `insecure-registries`; certificate import
is still useful for Git, browser-based tools, and diagnostics.
