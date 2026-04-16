# Internet PC Download Checklist

Everything in this list must be downloaded on the Internet PC (Windows 11) and transferred via USB into the air-gapped network, then uploaded to MinIO bucket `gitlab-runner-golden`.

---

## Binaries

| File | Version | Download URL | MinIO Key |
|------|---------|-------------|-----------|
| GitLab Runner | 16.7.0 | `https://gitlab-runner-downloads.s3.amazonaws.com/v16.7.0/binaries/gitlab-runner-windows-amd64.exe` | `binaries/gitlab-runner-16.7.0-windows-amd64.exe` |
| Docker CLI | 25.0.15 | `https://download.docker.com/win/static/stable/x86_64/docker-25.0.15.zip` → extract `docker.exe` | `binaries/docker/docker.exe` |
| Docker daemon | 25.0.15 | Same zip → extract `dockerd.exe` | `binaries/docker/dockerd.exe` |
| MinGit | 2.43.0 | `https://github.com/git-for-windows/git/releases/download/v2.43.0.windows.1/MinGit-2.43.0-64-bit.zip` | `binaries/git/MinGit-2.43.0-64-bit.zip` |

---

## Tools

| File | Version | Download URL | MinIO Key |
|------|---------|-------------|-----------|
| WinRAR | 7.01 | `https://www.win-rar.com/fileadmin/winrar-versions/winrar-x64-701.exe` | `tools/winrar-x64-701.exe` |
| NSSM | 2.24 | `https://nssm.cc/release/nssm-2.24.zip` | `tools/nssm-2.24.zip` |
| Process Explorer | latest | `https://download.sysinternals.com/files/ProcessExplorer.zip` → extract `procexp64.exe` | `tools/sysinternals/procexp64.exe` |
| Process Monitor | latest | `https://download.sysinternals.com/files/ProcessMonitor.zip` → extract `Procmon64.exe` | `tools/sysinternals/Procmon64.exe` |
| Handle | latest | `https://download.sysinternals.com/files/Handle.zip` → extract `handle64.exe` | `tools/sysinternals/handle64.exe` |
| PSTools | latest | `https://download.sysinternals.com/files/PSTools.zip` | `tools/sysinternals/PSTools.zip` |

---

## Container Images (for Harbor)

These must be pulled on the Internet PC, saved as tar, transferred via USB, and loaded + pushed to Harbor.

```powershell
# On Internet PC — pull and save
docker pull mcr.microsoft.com/windows/servercore:ltsc2019
docker pull mcr.microsoft.com/windows:ltsc2019
docker pull gitlab/gitlab-runner-helper:x86_64-v16.7.0-servercore1809

docker save mcr.microsoft.com/windows/servercore:ltsc2019 -o servercore-ltsc2019.tar
docker save mcr.microsoft.com/windows:ltsc2019 -o windows-ltsc2019.tar
docker save gitlab/gitlab-runner-helper:x86_64-v16.7.0-servercore1809 -o helper-v16.7.0.tar
```

```powershell
# On air-gapped machine — load, tag, push to Harbor
docker load -i servercore-ltsc2019.tar
docker load -i windows-ltsc2019.tar
docker load -i helper-v16.7.0.tar

docker tag mcr.microsoft.com/windows/servercore:ltsc2019 harbor.kayhut.com/golden-image/servercore:ltsc2019
docker tag mcr.microsoft.com/windows:ltsc2019 harbor.kayhut.com/golden-image/windows:ltsc2019
docker tag gitlab/gitlab-runner-helper:x86_64-v16.7.0-servercore1809 harbor.kayhut.com/golden-image/gitlab-runner-helper:x86_64-v16.7.0-servercore1809

docker push harbor.kayhut.com/golden-image/servercore:ltsc2019
docker push harbor.kayhut.com/golden-image/windows:ltsc2019
docker push harbor.kayhut.com/golden-image/gitlab-runner-helper:x86_64-v16.7.0-servercore1809
```

---

## USB Transfer Summary

After downloading everything, the USB should contain:

```
USB/
├── binaries/
│   ├── gitlab-runner-16.7.0-windows-amd64.exe
│   ├── docker-25.0.15.zip  (or extracted docker.exe + dockerd.exe)
│   └── MinGit-2.43.0-64-bit.zip
├── tools/
│   ├── winrar-x64-701.exe
│   ├── nssm-2.24.zip
│   └── sysinternals/
│       ├── procexp64.exe
│       ├── Procmon64.exe
│       ├── handle64.exe
│       └── PSTools.zip
├── images/
│   ├── servercore-ltsc2019.tar
│   ├── windows-ltsc2019.tar
│   └── helper-v16.7.0.tar
└── scripts/
    ├── Install-GitLabRunner.ps1
    ├── health-check.ps1
    ├── docker-watchdog.ps1
    ├── disk-monitor.ps1
    ├── kill-stale-containers.ps1
    └── Register-ScheduledTasks.ps1
```

Upload binaries/tools/scripts to MinIO bucket `gitlab-runner-golden`.
Load + tag + push container images to Harbor project `golden-image`.
