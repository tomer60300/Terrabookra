<#
.SYNOPSIS
    Install + enable OpenSSH Server on the base template, OFFLINE-first.

.DESCRIPTION
    Runs from autounattend FirstLogonCommands on the WS2019 base build, before any
    repo is uploaded. Air-gapped builds cannot use Add-WindowsCapability (needs a
    Feature-on-Demand source), so this prefers a bundled OpenSSH-Win64.zip carried
    on the Packer cd_files ISO (scans drives for it), and only falls back to
    Add-WindowsCapability when no offline zip is found (online/FoD-available).

    The result is the same either way: sshd + ssh-agent set Automatic and started,
    the firewall opened on 22, and PowerShell set as the default SSH shell so
    Packer's SSH communicator connects.

.NOTES
    File: packer/base/setup-openssh.ps1
    PowerShell 5.1. Self-contained -- no project lib dependencies (base has none yet).
#>
$ErrorActionPreference = 'Stop'
function Log { param($m) Write-Output "[setup-openssh] $m" }

$installed = $false

# 1. OFFLINE: find OpenSSH-Win64.zip on any drive (the cd_files ISO).
$zip = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
       ForEach-Object { Join-Path $_.Root 'OpenSSH-Win64.zip' } |
       Where-Object { Test-Path $_ } | Select-Object -First 1
if ($zip) {
    Log "Found offline OpenSSH zip: $zip"
    $dest = 'C:\Program Files\OpenSSH'
    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    $tmp = Join-Path $env:TEMP 'openssh-extract'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $src = Get-ChildItem $tmp -Recurse -Filter 'sshd.exe' | Select-Object -First 1
    if (-not $src) { throw 'sshd.exe not found in OpenSSH zip' }
    Copy-Item -Path (Join-Path $src.DirectoryName '*') -Destination $dest -Recurse -Force
    $installSshd = Join-Path $dest 'install-sshd.ps1'
    if (Test-Path $installSshd) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installSshd }
    $installed = $true
} else {
    # 2. ONLINE/FoD fallback (NOT air-gap safe -- needs a capability source).
    Log 'No offline zip found -- falling back to Add-WindowsCapability (requires FoD/internet).'
    Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
    $installed = $true
}

if (-not $installed) { throw 'OpenSSH was not installed by any method' }

# 3. Service + firewall + default shell (same for both paths).
Set-Service sshd -StartupType Automatic
Set-Service ssh-agent -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service sshd
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Enabled True | Out-Null
}
# The offline install-sshd.ps1 registers the sshd service but does NOT create the
# HKLM:\SOFTWARE\OpenSSH key. New-ItemProperty does not create a missing parent key
# (-Force only overwrites an existing value), so under $ErrorActionPreference='Stop'
# the next line throws and fails the base build on the air-gap path -- create it first.
if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) {
    New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
}
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
    -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null
Log 'OpenSSH ready (sshd running, port 22 open, PowerShell default shell).'
