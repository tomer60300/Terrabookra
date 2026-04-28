<#
.SYNOPSIS
    Configure Windows Terminal (portable distribution) with a machine-wide
    settings.json and convenient shortcuts on Windows Server 2019.

.DESCRIPTION
    The runner installs Windows Terminal as the **portable distribution**
    (zip extracted to C:\Program Files\WindowsTerminal\), NOT the AppX/MSIX
    package. The two distributions read settings from different places:

        AppX     -> %LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\
                    LocalState\settings.json   (per-user, AppX-only)
        Portable -> <install_dir>\settings\settings.json  (machine-wide,
                    enabled by a `.portable` marker file next to wt.exe)

    For a multi-user runner VM where every user should see the same Terminal
    profiles, **portable mode is the simpler, correct choice** -- one
    settings.json, edited once, applies to every user.

    What this script does:
      1. Drop a `.portable` marker file alongside wt.exe so Windows Terminal
         reads from the install dir instead of AppX.
      2. Write the machine-wide settings.json with PowerShell + CMD profiles
         to <install_dir>\settings\settings.json.
      3. Replace the Default User Start Menu entries for PowerShell and CMD
         with shortcuts that launch Terminal at the matching profile -- new
         users see "Windows PowerShell (Terminal)" and "Command Prompt
         (Terminal)" in their Start Menu.
      4. Add the install dir to machine PATH so `wt` works in any shell.

    On Windows Server 2019 LTSC there is NO OS-level "default terminal
    application" hook (DelegationConsole/DelegationTerminal exist on Win11
    only). What this script does covers every interactive user path. A
    process that explicitly spawns conhost.exe still uses the legacy host.

.PARAMETER InstallDir
    Where the portable Windows Terminal zip was extracted.
    Default: C:\Program Files\WindowsTerminal

.NOTES
    File:        scripts/Set-WindowsTerminalDefault.ps1
    Run as:      Administrator
    Called from: Install-Tools.ps1 PostInstall hook for WindowsTerminal
    Idempotent:  Yes -- safe to re-run.
#>

param(
    [string]$InstallDir = 'C:\Program Files\WindowsTerminal'
)

$ErrorActionPreference = 'Continue'

function Write-Step {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Output "[$ts] [$Level] $Message"
}

# ============================================================
# 1. Locate wt.exe
# ============================================================
$wtExe = Join-Path $InstallDir 'wt.exe'
if (-not (Test-Path $wtExe)) {
    Write-Step "  ERROR: wt.exe not found at $wtExe" 'ERROR'
    exit 2
}
Write-Step "  Windows Terminal binary: $wtExe"

# ============================================================
# 2. Enable portable mode -- empty `.portable` marker file
# ============================================================
$portableMarker = Join-Path $InstallDir '.portable'
if (-not (Test-Path $portableMarker)) {
    New-Item -Path $portableMarker -ItemType File -Force | Out-Null
    Write-Step "  Created portable-mode marker: $portableMarker"
} else {
    Write-Step "  Portable-mode marker already present"
}

# ============================================================
# 3. Machine-wide settings.json -- portable mode reads from
#    <InstallDir>\settings\settings.json
# ============================================================
$settingsDir  = Join-Path $InstallDir 'settings'
$settingsFile = Join-Path $settingsDir 'settings.json'
if (-not (Test-Path $settingsDir)) {
    New-Item -Path $settingsDir -ItemType Directory -Force | Out-Null
}

$settingsJson = @'
{
    "$schema": "https://aka.ms/terminal-profiles-schema",
    "defaultProfile": "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}",
    "copyOnSelect": true,
    "copyFormatting": "none",
    "showTabsInTitlebar": true,
    "alwaysShowTabs": true,
    "profiles": {
        "defaults": {
            "fontFace": "Cascadia Mono",
            "fontSize": 11,
            "historySize": 20000,
            "snapOnInput": true
        },
        "list": [
            {
                "guid": "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}",
                "name": "Windows PowerShell",
                "commandline": "powershell.exe -NoLogo",
                "hidden": false,
                "startingDirectory": "%USERPROFILE%",
                "icon": "ms-appx:///ProfileIcons/{61c54bbd-c2c6-5271-96e7-009a87ff44bf}.png"
            },
            {
                "guid": "{0caa0dad-35be-5f56-a8ff-afceeeaa6101}",
                "name": "Command Prompt",
                "commandline": "cmd.exe /K",
                "hidden": false,
                "startingDirectory": "%USERPROFILE%",
                "icon": "ms-appx:///ProfileIcons/{0caa0dad-35be-5f56-a8ff-afceeeaa6101}.png"
            }
        ]
    },
    "schemes": [],
    "actions": []
}
'@

$settingsJson | Out-File -FilePath $settingsFile -Encoding UTF8 -Force
Write-Step "  Wrote machine-wide settings: $settingsFile"

# Allow every interactive user to read the file (only Admins/SYSTEM can write)
try {
    $acl = Get-Acl $settingsFile
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @(
        (New-Object System.Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM',           'FullControl',     'Allow')),
        (New-Object System.Security.AccessControl.FileSystemAccessRule('BUILTIN\Administrators',        'FullControl',     'Allow')),
        (New-Object System.Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\Authenticated Users', 'ReadAndExecute', 'Allow'))
    )) { $acl.AddAccessRule($rule) }
    Set-Acl -Path $settingsFile -AclObject $acl
    Write-Step '  ACL: SYSTEM/Admins=Full, AuthUsers=Read'
} catch {
    Write-Step "  WARN: ACL set on settings.json failed: $_" 'WARN'
}

# ============================================================
# 4. PATH addition so `wt` is callable from any shell
# ============================================================
$currentPath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
if ($currentPath -notlike "*$InstallDir*") {
    [System.Environment]::SetEnvironmentVariable('PATH', "$currentPath;$InstallDir", 'Machine')
    Write-Step "  Added $InstallDir to machine PATH"
} else {
    Write-Step "  Machine PATH already contains $InstallDir"
}

# ============================================================
# 5. Default User Start Menu shortcuts -- new logons see
#    "Windows PowerShell (Terminal)" / "Command Prompt (Terminal)"
# ============================================================
function Set-Shortcut {
    param([string]$LinkPath, [string]$Target, [string]$Args, [string]$Icon = '')
    $dir = Split-Path $LinkPath -Parent
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($LinkPath)
    $sc.TargetPath = $Target
    $sc.Arguments  = $Args
    if ($Icon) { $sc.IconLocation = $Icon }
    $sc.Save()
}

$defaultStart = 'C:\Users\Default\AppData\Roaming\Microsoft\Windows\Start Menu\Programs'
Set-Shortcut -LinkPath (Join-Path $defaultStart 'Windows PowerShell (Terminal).lnk') `
             -Target $wtExe -Args '-p "Windows PowerShell"'
Set-Shortcut -LinkPath (Join-Path $defaultStart 'Command Prompt (Terminal).lnk') `
             -Target $wtExe -Args '-p "Command Prompt"'
Write-Step '  Default User Start Menu shortcuts created (PowerShell + CMD via Terminal)'

Write-Step '========== Set-WindowsTerminalDefault COMPLETE =========='
Write-Output ''
Write-Output 'Coverage:'
Write-Output "  - Portable mode marker      : $portableMarker"
Write-Output "  - Machine-wide settings     : $settingsFile (read by every user)"
Write-Output '  - Start Menu shortcuts      : new logons see PowerShell/CMD via Terminal'
Write-Output '  - `wt` on PATH              : callable from any shell'
Write-Output ''
Write-Output 'Note: WS2019 has no OS-level "default terminal" hook, so a process'
Write-Output 'that explicitly spawns conhost.exe still uses the legacy host. All'
Write-Output 'interactive user paths are covered.'
Write-Output ''
exit 0
