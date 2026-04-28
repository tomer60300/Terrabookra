<#
.SYNOPSIS
    Install OpenCode desktop with WebView2 prerequisite + machine-wide config.

.DESCRIPTION
    Idempotent, air-gap friendly installer for OpenCode on a runner VM.

    Steps:
      1. Detect WebView2 Evergreen runtime. If absent, install from S3-staged
         standalone installer (silent /install).
      2. Detect OpenCode desktop. If absent, install from S3-staged setup.exe
         (Squirrel installer -- accepts --silent).
      3. Place opencode.jsonc at the machine-wide path (default
         C:\ProgramData\opencode\opencode.jsonc) with read access for all
         authenticated users and write only for admins.
      4. Set the OPENCODE_CONFIG machine environment variable to that path
         so every user on the VM reads the same config.

    Called by Phase 3 (step 3.12) but also runnable standalone after a fresh
    re-deploy of binaries from MinIO.

.PARAMETER WebView2Installer
    Local path to the staged WebView2 standalone installer.
    Default: C:\Tools\WebView2\MicrosoftEdgeWebView2RuntimeInstallerX64.exe

.PARAMETER OpenCodeInstaller
    Local path to the staged OpenCode desktop setup.exe.
    Default: C:\Tools\opencode\opencode-desktop-windows-x64-setup.exe

.PARAMETER OpenCodeConfigSource
    Local path to the staged opencode.jsonc to publish machine-wide.
    Default: C:\Tools\opencode\opencode.jsonc

.PARAMETER MachineConfigPath
    Final machine-wide path for opencode.jsonc. Every user reads from here
    via the OPENCODE_CONFIG environment variable.
    Default: C:\ProgramData\opencode\opencode.jsonc

.NOTES
    File:        scripts/Install-OpenCode.ps1
    Requires:    Run as Administrator. Stages must already be on disk
                 (downloaded from MinIO by the caller).
    Idempotent:  Yes -- detects existing installs and skips re-installation.
#>

param(
    [string]$WebView2Installer    = 'C:\Tools\WebView2\MicrosoftEdgeWebView2RuntimeInstallerX64.exe',
    [string]$OpenCodeInstaller    = 'C:\Tools\opencode\opencode-desktop-windows-x64-setup.exe',
    [string]$OpenCodeConfigSource = 'C:\Tools\opencode\opencode.jsonc',
    [string]$MachineConfigPath    = 'C:\ProgramData\opencode\opencode.jsonc'
)

$ErrorActionPreference = 'Continue'

# ============================================================
# CONSTANTS -- WebView2 detection registry locations
# ============================================================
# WebView2 Evergreen Runtime registers under one of these GUID keys depending
# on install scope (machine-wide x64 vs per-user). Either presence indicates
# the runtime is installed.
$WV2_KEY_MACHINE_X64 = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
$WV2_KEY_MACHINE_X86 = 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'

# ============================================================
# HELPERS
# ============================================================

function Write-Step {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Output "[$ts] [$Level] $Message"
}

function Get-WebView2Version {
    foreach ($key in @($WV2_KEY_MACHINE_X64, $WV2_KEY_MACHINE_X86)) {
        if (Test-Path $key) {
            $pv = (Get-ItemProperty -Path $key -Name pv -ErrorAction SilentlyContinue).pv
            if ($pv) { return $pv }
        }
    }
    return $null
}

function Test-OpenCodeInstalled {
    # Squirrel installs to %LOCALAPPDATA%\Programs\opencode by default for the
    # current user, OR C:\Program Files\opencode for per-machine. We check
    # several plausible locations; any hit means installed.
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\opencode\opencode.exe",
        "$env:ProgramFiles\opencode\opencode.exe",
        'C:\Program Files\opencode\opencode.exe',
        'C:\Program Files (x86)\opencode\opencode.exe'
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# ============================================================
# 1. WebView2 -- prerequisite for OpenCode
# ============================================================
Write-Step '========== Install-OpenCode =========='
Write-Step '1/4  WebView2 runtime'

$wv2Version = Get-WebView2Version
if ($wv2Version) {
    Write-Step "  WebView2 already installed (version $wv2Version) -- skip"
} else {
    if (-not (Test-Path $WebView2Installer)) {
        Write-Step "  FATAL: WebView2 installer not found at $WebView2Installer" 'ERROR'
        Write-Step '         OpenCode cannot run without WebView2. Aborting.' 'ERROR'
        exit 2
    }
    Write-Step "  Running silent install: $WebView2Installer /silent /install"
    $proc = Start-Process -FilePath $WebView2Installer -ArgumentList '/silent','/install' -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        Write-Step "  FATAL: WebView2 installer exited $($proc.ExitCode)" 'ERROR'
        exit 3
    }
    $wv2Version = Get-WebView2Version
    if (-not $wv2Version) {
        Write-Step '  FATAL: WebView2 installer reported success but registry key absent' 'ERROR'
        exit 4
    }
    Write-Step "  WebView2 installed successfully (version $wv2Version)"
}

# ============================================================
# 2. OpenCode desktop -- silent install
# ============================================================
Write-Step '2/4  OpenCode desktop'

$existingExe = Test-OpenCodeInstalled
if ($existingExe) {
    Write-Step "  OpenCode already installed at $existingExe -- skip"
} else {
    if (-not (Test-Path $OpenCodeInstaller)) {
        Write-Step "  FATAL: OpenCode installer not found at $OpenCodeInstaller" 'ERROR'
        exit 5
    }
    # OpenCode desktop ships an NSIS installer, NOT a Squirrel one (confirmed
    # by the official download URL `opencode.ai/download/stable/windows-x64-nsis`).
    # NSIS silent flag is /S (capital S, no equals sign); --silent is a
    # Squirrel convention and would be ignored or trigger a UI prompt.
    Write-Step "  Running silent install: $OpenCodeInstaller /S"
    $proc = Start-Process -FilePath $OpenCodeInstaller -ArgumentList '/S' -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        Write-Step "  WARN: OpenCode installer exited $($proc.ExitCode) -- verifying anyway" 'WARN'
    }
    $existingExe = Test-OpenCodeInstalled
    if (-not $existingExe) {
        Write-Step '  FATAL: OpenCode installer ran but no opencode.exe found in expected paths' 'ERROR'
        exit 6
    }
    Write-Step "  OpenCode installed at $existingExe"
}

# ============================================================
# 3. Machine-wide opencode.jsonc
# ============================================================
Write-Step '3/4  Machine-wide opencode.jsonc'

if (-not (Test-Path $OpenCodeConfigSource)) {
    Write-Step "  FATAL: opencode.jsonc source not found at $OpenCodeConfigSource" 'ERROR'
    exit 7
}

$machineConfigDir = Split-Path -Parent $MachineConfigPath
if (-not (Test-Path $machineConfigDir)) {
    New-Item -Path $machineConfigDir -ItemType Directory -Force | Out-Null
}

Copy-Item -Path $OpenCodeConfigSource -Destination $MachineConfigPath -Force
Write-Step "  Copied opencode.jsonc to $MachineConfigPath"

# ACL: SYSTEM + Administrators full control, Authenticated Users read-only.
# Reset inheritance to ensure deterministic permissions across re-runs.
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)  # disable inheritance, drop existing
foreach ($rule in @(
    (New-Object System.Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM',       'FullControl',  'ContainerInherit,ObjectInherit', 'None', 'Allow')),
    (New-Object System.Security.AccessControl.FileSystemAccessRule('BUILTIN\Administrators',    'FullControl',  'ContainerInherit,ObjectInherit', 'None', 'Allow')),
    (New-Object System.Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\Authenticated Users', 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
)) { $acl.AddAccessRule($rule) }
Set-Acl -Path $machineConfigDir -AclObject $acl
Write-Step "  ACL set on $machineConfigDir (SYSTEM/Admins=Full, AuthUsers=Read)"

# ============================================================
# 4. OPENCODE_CONFIG machine env var
# ============================================================
Write-Step '4/4  OPENCODE_CONFIG machine environment variable'

$current = [System.Environment]::GetEnvironmentVariable('OPENCODE_CONFIG', 'Machine')
if ($current -eq $MachineConfigPath) {
    Write-Step "  OPENCODE_CONFIG already set to $MachineConfigPath -- skip"
} else {
    [System.Environment]::SetEnvironmentVariable('OPENCODE_CONFIG', $MachineConfigPath, 'Machine')
    Write-Step "  Set OPENCODE_CONFIG = $MachineConfigPath (Machine scope)"
}

# Reflect into current process so any post-step that checks env sees it
$env:OPENCODE_CONFIG = $MachineConfigPath

Write-Step '========== Install-OpenCode COMPLETE =========='
Write-Output ''
Write-Output 'Summary:'
Write-Output "  WebView2:         $wv2Version"
Write-Output "  OpenCode binary:  $existingExe"
Write-Output "  Machine config:   $MachineConfigPath"
Write-Output "  OPENCODE_CONFIG:  $MachineConfigPath (Machine env)"
Write-Output ''

exit 0
