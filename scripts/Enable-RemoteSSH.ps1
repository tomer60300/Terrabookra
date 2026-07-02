<#
.SYNOPSIS
    Install OpenSSH-Win64 from a staged zip and configure it as the remote
    administration channel for this runner.

.DESCRIPTION
    Replaces the prior WinRM-based remote channel, which is blocked by
    domain GPO at Kayhut. Uses the official PowerShell/Win32-OpenSSH
    portable zip release -- no Windows-Update / Add-WindowsCapability
    dependency, no BITS service required. Works fully air-gapped.

    Steps:
      1. Extract OpenSSH-Win64.zip to %ProgramFiles%\OpenSSH if not already there
      2. Run the bundled install-sshd.ps1 to register the sshd service
      3. Set sshd startup type Automatic and start the service
      4. Open inbound TCP 22 in Windows Firewall
      5. Set the SSH default shell to PowerShell so 'ssh host cmd' lands you
         in PS by default (the OpenSSH default is cmd.exe)
      6. Write a marker-delimited managed block in C:\ProgramData\ssh\sshd_config
         that explicitly enables PasswordAuthentication (so AD users can log in
         with their domain password via the Windows logon stack) and optionally
         restricts SSH access to a set of AD groups via AllowGroups.
      7. (Optional) If a staged administrators_authorized_keys file exists,
         copy it to C:\ProgramData\ssh\administrators_authorized_keys with the
         strict ACL the Win32 OpenSSH server requires (SYSTEM + BUILTIN\Administrators
         only, inheritance disabled). This file is OPTIONAL when AD password auth
         is sufficient -- only needed for public-key fallback.

    Auth model on a domain-joined runner:
      - PRIMARY:  AD password auth. `ssh DOMAIN\user@runner` prompts for AD
                  password; sshd hands it to Windows LogonUser; AD validates.
      - FALLBACK: Public-key auth via administrators_authorized_keys (machine-
                  wide for local Administrators group members) or per-user
                  %USERPROFILE%\.ssh\authorized_keys (for non-admin accounts).

    Idempotent: detects existing extraction, existing service, existing
    firewall rule, and existing authorized_keys -- safe to re-run.

.PARAMETER OpenSshZip
    Local path to the staged OpenSSH-Win64.zip.
    Default: C:\Tools\openssh\OpenSSH-Win64.zip

.PARAMETER InstallDir
    Where the zip is extracted to. Must contain sshd.exe and install-sshd.ps1
    after extraction.
    Default: C:\Program Files\OpenSSH

.PARAMETER AuthorizedKeysSource
    Local path to the staged administrators_authorized_keys file (one or more
    public keys, one per line). If absent, the script still installs the
    server but skips key deployment -- you'd configure auth manually later.
    Default: C:\Tools\openssh\administrators_authorized_keys

.PARAMETER FirewallRuleName
    Name of the inbound firewall rule for sshd.
    Default: OpenSSH-Server-In-TCP

.NOTES
    File:        scripts/Enable-RemoteSSH.ps1
    Replaces:    scripts/Enable-RemotePowerShell.ps1 (WinRM, blocked by GPO)
    Run as:      Administrator
    Called from: Phase 1 step 1.11
#>

param(
    [string]$OpenSshZip           = 'C:\Tools\openssh\OpenSSH-Win64.zip',
    [string]$InstallDir           = 'C:\Program Files\OpenSSH',
    [string]$AuthorizedKeysSource = 'C:\Tools\openssh\administrators_authorized_keys',
    [string]$FirewallRuleName     = 'OpenSSH-Server-In-TCP',
    # AD/LDAP auth: AllowedADGroups is an optional whitelist of AD groups that
    # may SSH in. Empty = unrestricted (default Windows OpenSSH behaviour).
    # Format: 'DOMAIN\Group Name' per entry. Group names with spaces are
    # quoted automatically when written to sshd_config.
    [string[]]$AllowedADGroups    = @()
)

$ErrorActionPreference = 'Continue'

function Write-Step {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Output "[$ts] [$Level] $Message"
}

# ============================================================
# 1. Extract OpenSSH-Win64.zip
# ============================================================
Write-Step '========== Enable-RemoteSSH =========='
Write-Step '1/6  Extract OpenSSH binaries'

$sshdExe       = Join-Path $InstallDir 'sshd.exe'
$installSshScr = Join-Path $InstallDir 'install-sshd.ps1'

if ((Test-Path $sshdExe) -and (Test-Path $installSshScr)) {
    Write-Step "  Existing OpenSSH install detected at $InstallDir -- skip extraction"
} else {
    if (-not (Test-Path $OpenSshZip)) {
        Write-Step "  FATAL: OpenSSH zip not found at $OpenSshZip" 'ERROR'
        exit 2
    }
    if (-not (Test-Path $InstallDir)) {
        New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
    }
    # The zip's top-level folder is "OpenSSH-Win64\" -- extract to a temp
    # location, then move the contents up one level into $InstallDir.
    $tmp = Join-Path $env:TEMP "openssh-extract-$([Guid]::NewGuid().ToString('N'))"
    New-Item -Path $tmp -ItemType Directory -Force | Out-Null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($OpenSshZip, $tmp)
        $inner = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
        if ($inner) {
            Get-ChildItem -Path $inner.FullName -Force | Copy-Item -Destination $InstallDir -Recurse -Force
        } else {
            # Zip had no top-level folder -- copy directly
            Get-ChildItem -Path $tmp -Force | Copy-Item -Destination $InstallDir -Recurse -Force
        }
        Write-Step "  Extracted to $InstallDir"
    } finally {
        Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $sshdExe)) {
        Write-Step "  FATAL: sshd.exe missing after extraction at $sshdExe" 'ERROR'
        exit 3
    }
}

# ============================================================
# 2. Register sshd service (via bundled install-sshd.ps1)
# ============================================================
Write-Step '2/6  Register sshd service'

$existingSvc = Get-Service sshd -ErrorAction SilentlyContinue
if ($existingSvc) {
    Write-Step "  sshd service already registered -- skip install-sshd.ps1"
} else {
    if (-not (Test-Path $installSshScr)) {
        Write-Step "  FATAL: install-sshd.ps1 missing at $installSshScr" 'ERROR'
        exit 4
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installSshScr 2>&1 |
        ForEach-Object { Write-Step "  install-sshd: $_" }
    $existingSvc = Get-Service sshd -ErrorAction SilentlyContinue
    if (-not $existingSvc) {
        Write-Step '  FATAL: sshd service not registered after install-sshd.ps1' 'ERROR'
        exit 5
    }
    Write-Step '  sshd service registered'
}

# ============================================================
# 3. sshd auto-start + start
# ============================================================
Write-Step '3/6  Configure sshd startup + start'

try {
    Set-Service -Name sshd -StartupType Automatic -ErrorAction Stop
    Write-Step '  sshd StartupType=Automatic'
} catch {
    Write-Step "  WARN: Set-Service sshd failed: $_" 'WARN'
}
try {
    Start-Service -Name sshd -ErrorAction Stop
} catch {
    Write-Step "  WARN: Start-Service sshd failed (already running?): $_" 'WARN'
}
$svc = Get-Service sshd -ErrorAction SilentlyContinue
Write-Step "  sshd status: $($svc.Status)"
# SSH is the remote control plane. If sshd is not Running, Packer and fleet
# operations lose remote access after the next reboot -- fail hard so the build
# aborts instead of producing an unreachable VM.
if (-not $svc -or $svc.Status -ne 'Running') {
    Write-Step "  FATAL: sshd is not Running (status: $($svc.Status)). SSH control plane unavailable." 'ERROR'
    exit 5
}

# ssh-agent (used by some workflows; harmless to enable)
try {
    Set-Service -Name ssh-agent -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name ssh-agent -ErrorAction SilentlyContinue
    Write-Step '  ssh-agent: Automatic, started'
} catch {
    Write-Step "  ssh-agent setup skipped: $_" 'WARN'
}

# ============================================================
# 4. Firewall -- inbound TCP 22
# ============================================================
Write-Step '4/6  Firewall rule for TCP 22 inbound'

$fwRule = Get-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue
if ($fwRule) {
    Write-Step "  Firewall rule '$FirewallRuleName' already exists"
} else {
    New-NetFirewallRule `
        -Name        $FirewallRuleName `
        -DisplayName 'OpenSSH Server (sshd)' `
        -Description 'Inbound TCP 22 for OpenSSH server' `
        -Enabled     True `
        -Direction   Inbound `
        -Protocol    TCP `
        -LocalPort   22 `
        -Action      Allow | Out-Null
    Write-Step "  Created firewall rule '$FirewallRuleName'"
}

# ============================================================
# 5. Default shell = PowerShell
# ============================================================
Write-Step '5/6  Set default SSH shell to PowerShell'

$openSshRegPath = 'HKLM:\SOFTWARE\OpenSSH'
if (-not (Test-Path $openSshRegPath)) {
    New-Item -Path $openSshRegPath -Force | Out-Null
}
$psPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$current = (Get-ItemProperty -Path $openSshRegPath -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
if ($current -eq $psPath) {
    Write-Step "  DefaultShell already set to PowerShell"
} else {
    New-ItemProperty -Path $openSshRegPath -Name DefaultShell -Value $psPath -PropertyType String -Force | Out-Null
    Write-Step "  DefaultShell = $psPath"
}

# ============================================================
# 6. AD-friendly sshd_config -- explicit password auth, optional
#    AllowGroups whitelist
#
#    Domain-joined runners get AD password auth automatically because
#    sshd hands password attempts to the Windows logon stack, which
#    validates against the DC. We just need to make sure password auth
#    isn't disabled by some hardening tool. AllowGroups (when set)
#    restricts who is permitted to log in -- a least-privilege win
#    if you have a dedicated "DevOps" or "Runner-Admins" AD group.
#
#    Idempotency: a marker block delimits our managed directives so we
#    can replace them on every re-run without duplicating lines.
# ============================================================
Write-Step '6/7  Configure sshd_config for AD password auth'

$sshConfigDir  = 'C:\ProgramData\ssh'
$sshdConfig    = Join-Path $sshConfigDir 'sshd_config'
$markerStart   = '# === BEGIN Terrabookra-managed (AD auth) ==='
$markerEnd     = '# === END Terrabookra-managed (AD auth) ==='

if (-not (Test-Path $sshdConfig)) {
    Write-Step "  WARN: $sshdConfig not present -- install-sshd.ps1 should have created it" 'WARN'
} else {
    # Build the managed block fresh each run.
    $lines = @(
        $markerStart,
        '# AD-aware authentication. Edit OpenSshAllowedADGroups in Config.ps1',
        '# to restrict access to specific AD groups; re-run Enable-RemoteSSH.ps1.',
        '',
        '# Password auth is the primary mechanism on this domain-joined host.',
        '# sshd routes password attempts through the Windows logon stack which',
        '# validates against Active Directory.',
        'PasswordAuthentication yes',
        '',
        '# Public keys still work as a fallback (e.g. for fleet automation).',
        'PubkeyAuthentication yes'
    )
    if ($AllowedADGroups -and $AllowedADGroups.Count -gt 0) {
        # Group names containing a space must be quoted on the AllowGroups line.
        $quoted = $AllowedADGroups | ForEach-Object {
            if ($_ -match '\s') { "`"$_`"" } else { $_ }
        }
        $lines += ''
        $lines += ('# Restricted to: ' + ($AllowedADGroups -join ', '))
        $lines += ('AllowGroups ' + ($quoted -join ' '))
    } else {
        $lines += ''
        $lines += '# AllowGroups not set -- any user with valid AD credentials +'
        $lines += '# "Allow log on locally" rights may SSH in.'
    }
    $lines += $markerEnd

    $managedBlock = ($lines -join "`r`n") + "`r`n"

    # Strip a previous block (idempotent re-write) before appending.
    $existing  = Get-Content $sshdConfig -Raw -ErrorAction SilentlyContinue
    if ($existing -match [regex]::Escape($markerStart)) {
        $pattern   = '(?s)' + [regex]::Escape($markerStart) + '.*?' + [regex]::Escape($markerEnd) + '\r?\n?'
        $existing  = [regex]::Replace($existing, $pattern, '')
    }
    $newConfig = ($existing.TrimEnd("`r","`n") + "`r`n`r`n" + $managedBlock).TrimStart()
    $newConfig | Out-File -FilePath $sshdConfig -Encoding ascii -NoNewline -Force

    if ($AllowedADGroups -and $AllowedADGroups.Count -gt 0) {
        Write-Step ("  AllowGroups set -- restricted to: " + ($AllowedADGroups -join ', '))
    } else {
        Write-Step '  AllowGroups not set -- any AD user with logon rights may SSH'
    }
    Write-Step '  PasswordAuthentication yes (AD auth via Windows logon stack)'

    # Restart sshd so the new config takes effect immediately.
    Restart-Service sshd -Force -ErrorAction SilentlyContinue
    Write-Step '  sshd restarted to apply config changes'
}

# ============================================================
# 7. authorized_keys for the local Administrators group (OPTIONAL)
# ============================================================
Write-Step '7/7  Deploy administrators_authorized_keys (optional, key-based fallback)'

$sshDataDir   = 'C:\ProgramData\ssh'
$authKeysFile = Join-Path $sshDataDir 'administrators_authorized_keys'

if (-not (Test-Path $sshDataDir)) {
    New-Item -Path $sshDataDir -ItemType Directory -Force | Out-Null
}

if (Test-Path $AuthorizedKeysSource) {
    Copy-Item -Path $AuthorizedKeysSource -Destination $authKeysFile -Force
    Write-Step "  Copied keys from $AuthorizedKeysSource"

    # Strict ACL: SYSTEM + Administrators only, inheritance disabled.
    # OpenSSH server REFUSES to use this file if any other principal has access.
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)  # disable inheritance, drop existing
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        'NT AUTHORITY\SYSTEM', 'FullControl', 'Allow')))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        'BUILTIN\Administrators', 'FullControl', 'Allow')))
    Set-Acl -Path $authKeysFile -AclObject $acl
    Write-Step "  ACL set: SYSTEM + Administrators only"

    # Restart sshd so it picks up the new keys
    Restart-Service sshd -Force -ErrorAction SilentlyContinue
    Write-Step '  sshd restarted to load new keys'
} else {
    Write-Step "  WARN: $AuthorizedKeysSource not present -- skipping key deployment." 'WARN'
    Write-Step '         Server is up but key-based auth will not work until you' 'WARN'
    Write-Step "         drop a public key into $authKeysFile manually." 'WARN'
}

# ============================================================
# Summary
# ============================================================
Write-Step '========== Enable-RemoteSSH COMPLETE =========='
$status = (Get-Service sshd -ErrorAction SilentlyContinue).Status
$keyState = if (Test-Path $authKeysFile) { 'present (key auth enabled)' } else { 'absent (AD password only)' }
$groupRestriction = if ($AllowedADGroups -and $AllowedADGroups.Count -gt 0) {
    "restricted to: $($AllowedADGroups -join ', ')"
} else {
    'unrestricted (any AD user with logon rights)'
}
Write-Output ''
Write-Output 'Summary:'
Write-Output "  Install dir:       $InstallDir"
Write-Output "  sshd status:       $status"
Write-Output "  Firewall rule:     $FirewallRuleName (TCP 22)"
Write-Output "  Default shell:     $psPath"
Write-Output "  AD auth:           $groupRestriction"
Write-Output "  authorized_keys:   $authKeysFile -- $keyState"
Write-Output ''
Write-Output "Login from your local PC:"
Write-Output "  ssh DOMAIN\username@$env:COMPUTERNAME           # AD password auth"
Write-Output "  ssh -i <private-key> Administrator@$env:COMPUTERNAME   # SSH key auth (if deployed)"
Write-Output ''

exit 0
