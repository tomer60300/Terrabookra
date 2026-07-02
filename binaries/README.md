# `binaries/`

Runtime binaries used by the Packer golden-image build.

These files are Git LFS artifacts on the internal leg. The public leg may carry
only pointers or placeholders; run `git lfs checkout` after importing the transfer
bundle.

| File | Expected content |
| --- | --- |
| `gitlab-runner-16.7.0-windows-amd64.exe` | GitLab Runner `16.7.0`. |
| `docker/docker.exe` | Docker CLI `25.0.x`. |
| `docker/dockerd.exe` | Docker daemon `25.0.x`. |
| `git/MinGit.zip` | Offline MinGit archive. |

`validation/Test-BuildInputs.ps1` fails when these files are missing or still
materialized as Git LFS pointer text.
