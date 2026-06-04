<#
.SYNOPSIS
    Install OpenCode desktop with WebView2 prerequisite + machine-wide config.
    HARDENED build -- proof against the exit-6 "installed but not detected"
    failure (Cluster 2). See PATCH-NOTES.md.

.DESCRIPTION
    What changed vs 2.4.6/2.4.7:
      * Test-OpenCodeInstalled no longer relies on 4 hard-coded paths. Phase 3
        runs as SYSTEM, so a per-user (NSIS/electron-builder) install lands in
        the SYSTEM profile (C:\Windows\System32\config\systemprofile\AppData\
        Local\Programs\...) and/or a versioned subfolder -- both of which the
        old fixed list missed, producing a false exit 6 even though the
        installer succeeded. Detection now:
          1. reads the install location from the Uninstall registry key
             (written regardless of which profile installed it), and
          2. falls back to a recursive sweep of every plausible install root,
             including the SYSTEM profile.

    Steps:
      1. Detect/Install WebView2 Evergreen runtime (silent).
      2. Detect/Install OpenCode desktop (NSIS silent /S).
      3. Publish opencode.jsonc machine-wide (C:\ProgramData\opencode\).
      4. Set OPENCODE_CONFIG machine env var to that path.

.PARAMETER WebView2Installer    Local path to staged WebView2 installer.
.PARAMETER OpenCodeInstaller    Local path to staged OpenCode setup.exe.
.PARAMETER OpenCodeConfigSource Local path to staged opencode.jsonc.
.PARAMETER MachineConfigPath    Final machine-wide path for opencode.jsonc.

.NOTES
    File:        scripts/Install-OpenCode.ps1
    Requires:    Run as Administrator. Stages must already be on disk.
    Idempotent:  Yes.
#>

param(
    [string]$WebView2Installer    = 'C:\Tools\WebView2\MicrosoftEdgeWebView2RuntimeInstallerX64.exe',
    [string]$OpenCodeInstaller    = 'C:\Tools\opencode\opencode-desktop-windows-x64-setup.exe',
    [string]$OpenCodeConfigSource = 'C:\Tools\opencode\opencode.jsonc',
    [string]$MachineConfigPath    = 'C:\ProgramData\opencode\opencode.jsonc'
)

$ErrorActionPreference = 'Continue'

# WebView2 Evergreen Runtime registry keys (machine-wide x64 / x86 scope).
$WV2_KEY_MACHINE_X64 = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
$WV2_KEY_MACHINE_X86 = 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'

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
    <#
    .SYNOPSIS  Return the path to opencode.exe if installed, else $null.
               Survives SYSTEM-profile and versioned-subfolder installs.
    #>

    # 1) Uninstall registry entry -- written no matter which profile installed it.
    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $uninstallRoots) {
        $hits = Get-ItemProperty $root -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match 'opencode' }
        foreach ($h in @($hits)) {
            if ($h.InstallLocation) {
                $exe = Join-Path $h.InstallLocation 'opencode.exe'
                if (Test-Path $exe) { return $exe }
            }
            if ($h.DisplayIcon) {
                $exe = ($h.DisplayIcon -replace '^"?([^"]+\.exe).*$', '$1')
                if ($exe -and (Test-Path $exe) -and ($exe -match 'opencode')) { return $exe }
            }
        }
    }

    # 2) Filesystem sweep across every plausible install root (incl. SYSTEM
    #    profile, since Phase 3 runs as SYSTEM). Handles versioned subfolders.
    $roots = @(
        "$env:LOCALAPPDATA\Programs",
        'C:\Windows\System32\config\systemprofile\AppData\Local\Programs',
        "$env:ProgramFiles",
        'C:\Program Files',
        'C:\Program Files (x86)'
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    # Fast path: the conventional leaf folders, no recursion.
    foreach ($r in $roots) {
        foreach ($leaf in @('opencode\opencode.exe', 'opencode-desktop\opencode.exe')) {
            $p = Join-Path $r $leaf
            if (Test-Path $p) { return $p }
        }
    }
    # Fallback: depth-bounded recurse (handles versioned subfolders like app-0.x.y)
    # without walking the entire Program Files tree (which can take minutes).
    foreach ($r in $roots) {
        $exe = Get-ChildItem -Path $r -Filter 'opencode.exe' -Recurse -Depth 3 -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($exe) { return $exe.FullName }
    }
    return $null
}

# ============================================================
# 1. WebView2 -- prerequisite for OpenCode
# ============================================================
Write-Step '========== Install-OpenCode (hardened) =========='
Write-Step '1/4  WebView2 runtime'

$wv2Version = Get-WebView2Version
if ($wv2Version) {
    Write-Step "  WebView2 already installed (version $wv2Version) -- skip"
} else {
    if (-not (Test-Path $WebView2Installer)) {
        Write-Step "  FATAL: WebView2 installer not found at $WebView2Installer" 'ERROR'
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
    # OpenCode desktop ships an NSIS installer (opencode.ai/download/stable/
    # windows-x64-nsis). NSIS silent flag is /S (capital S, no '=').
    Write-Step "  Running silent install: $OpenCodeInstaller /S"
    $proc = Start-Process -FilePath $OpenCodeInstaller -ArgumentList '/S' -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        Write-Step "  WARN: OpenCode installer exited $($proc.ExitCode) -- verifying anyway" 'WARN'
    }
    Start-Sleep -Seconds 3   # NSIS can return before the last file is flushed
    $existingExe = Test-OpenCodeInstalled
    if (-not $existingExe) {
        Write-Step '  FATAL: OpenCode installer ran but no opencode.exe found.' 'ERROR'
        Write-Step '         Searched registry Uninstall keys + these roots:' 'ERROR'
        foreach ($r in @("$env:LOCALAPPDATA\Programs",
                         'C:\Windows\System32\config\systemprofile\AppData\Local\Programs',
                         'C:\Program Files','C:\Program Files (x86)')) {
            Write-Step "           $r" 'ERROR'
        }
        Write-Step '         If the binary is elsewhere, add its root to Test-OpenCodeInstalled.' 'ERROR'
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
