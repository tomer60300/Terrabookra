<#
.SYNOPSIS
    Phase 1 — System preparation, services, environment, Windows features.

.DESCRIPTION
    Called by Install-GitLabRunner.ps1 when no phase markers exist.
    Prepares the VM for Docker and Runner installation:

    1.0  Pre-flight dependency validation (DNS, S3, Harbor)
    1.1  Register Event Log source
    1.2  Disable unnecessary Windows services (17 services)
    1.3  Set High Performance power plan
    1.4  Configure pagefile on data drive
    1.5  Network tuning + long paths
    1.6  Environment variables + PATH
    1.7  Create directory structure
    1.8  Increase Event Log sizes
    1.9  Install Windows Features (Containers + Hyper-V)

    Reboots via Be1 if features required it, otherwise continues to Phase 2.

.NOTES
    File: phases/Phase1-SystemPrep.ps1
    Requires: lib/Config.ps1, lib/Common.ps1 (dot-sourced by orchestrator)
#>

function Invoke-Phase1 {
    Write-Log '========== PHASE 1: System Preparation =========='

    # ── 1.0 Pre-flight dependency validation ─────────────────
    Write-Log '1.0 Pre-flight dependency validation (DNS + S3 + Harbor)'
    $depScript = Join-Path $PSScriptRoot '..\validation\Test-Dependencies.ps1'
    if (-not (Test-Path $depScript)) {
        # Fallback: try to fetch from S3
        $depScriptLocal = Join-Path $Script:Config.ScriptsDir 'Test-Dependencies.ps1'
        if (-not (Test-Path $depScriptLocal)) {
            Get-S3Object -Key $Script:Config.S3KeysExtra.DepValidator -OutFile $depScriptLocal | Out-Null
        }
        $depScript = $depScriptLocal
    }
    if (Test-Path $depScript) {
        $depResult = & $depScript 2>&1
        $depResult | ForEach-Object { Write-Log "  dep: $_" }
        # Extract summary — last object is the PSCustomObject
        $summary = $depResult | Where-Object { $_ -is [PSCustomObject] -and $_.Failed -ne $null } | Select-Object -Last 1
        if ($summary -and $summary.Failed -gt 0) {
            Write-LogWarn "Dependency check: $($summary.Failed) of $($summary.Total) failed — install may fail later"
        }
    } else {
        Write-LogWarn 'Test-Dependencies.ps1 not found — skipping pre-flight check'
    }

    # ── 1.1 Event Log source ─────────────────────────────────
    Write-Log '1.1 Register Event Log source'
    New-EventLog -LogName Application -Source 'GitLabRunner' -ErrorAction SilentlyContinue

    # ── 1.2 Disable unnecessary services ─────────────────────
    Write-Log '1.2 Disable unnecessary Windows services'
    foreach ($svc in $Script:Config.DisableServices) {
        $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($service) {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
            Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
        }
    }
    Write-Log "Processed $($Script:Config.DisableServices.Count) services"

    # ── 1.3 Power plan ───────────────────────────────────────
    Write-Log '1.3 Set High Performance power plan'
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c

    # ── 1.4 Page file ────────────────────────────────────────
    Write-Log '1.4 Configure page file'
    try {
        $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
        $pageFileMB = [math]::Min($ramGB * 1024, $Script:Config.PagefileMaxMB)
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem
        $cs | Set-CimInstance -Property @{ AutomaticManagedPagefile = $false }
        $pfDrive = $Script:DataDrive.TrimEnd(':')
        $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
        Set-ItemProperty -Path $regPath -Name 'PagingFiles' -Value "${pfDrive}:\pagefile.sys $pageFileMB $pageFileMB"
        Write-Log "Page file: ${pageFileMB}MB on ${pfDrive}: (RAM: ${ramGB}GB)"
    }
    catch { Write-LogWarn "Page file config failed: $_" }

    # ── 1.5 Network tuning + long paths ──────────────────────
    Write-Log '1.5 Network tuning + long paths'
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1 -Type DWord
    netsh int tcp set global autotuninglevel=normal 2>$null
    netsh int ipv4 set dynamicport tcp start=10000 num=55535 2>$null
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'TcpTimedWaitDelay' -Value 30 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name 'MaxCacheEntryTtlLimit' -Value 86400 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -Value 2 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name 'MinAnimate' -Value '0' -ErrorAction SilentlyContinue

    # ── 1.6 Environment variables + PATH ─────────────────────
    Write-Log '1.6 Set environment variables'
    [System.Environment]::SetEnvironmentVariable('GIT_SSL_NO_VERIFY', 'true', 'Machine')
    [System.Environment]::SetEnvironmentVariable('DOTNET_CLI_TELEMETRY_OPTOUT', '1', 'Machine')
    [System.Environment]::SetEnvironmentVariable('DOTNET_NOLOGO', '1', 'Machine')
    $currentPath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
    foreach ($p in @($Script:Config.DockerDir, (Join-Path $Script:Config.GitDir 'cmd'), $Script:Config.ToolsDir, $Script:Config.RunnerDir)) {
        if ($currentPath -notlike "*$p*") { $currentPath = "$currentPath;$p" }
    }
    [System.Environment]::SetEnvironmentVariable('PATH', $currentPath, 'Machine')
    $env:PATH = $currentPath

    # ── 1.7 Directory structure ──────────────────────────────
    Write-Log '1.7 Create directory structure'
    foreach ($d in @(
        $Script:Config.RunnerDir, $Script:Config.BuildsDir, $Script:Config.CacheDir,
        $Script:Config.LogsDir, $Script:Config.ScriptsDir, $Script:Config.GitDir,
        $Script:Config.ToolsDir, $Script:Config.SysInternalsDir,
        $Script:Config.DockerConfigDir, $Script:Config.DockerDir
    )) {
        if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
    }

    # ── 1.8 Event Log sizes ─────────────────────────────────
    Write-Log '1.8 Event Log sizes'
    wevtutil sl Application /ms:104857600 2>$null
    wevtutil sl System /ms:104857600 2>$null
    wevtutil sl Security /ms:52428800 2>$null

    # ── 1.9 Windows Features ─────────────────────────────────
    Write-Log '1.9 Install Windows Features (Containers, Hyper-V)'
    $needReboot = $false

    $containersFeature = Get-WindowsFeature -Name Containers
    if (-not $containersFeature.Installed) {
        Write-Log 'Installing Containers feature...'
        $result = Install-WindowsFeature -Name Containers
        if ($result.RestartNeeded -eq 'Yes') { $needReboot = $true }
    } else { Write-Log 'Containers: already installed' }

    $hypervFeature = Get-WindowsFeature -Name Hyper-V
    if (-not $hypervFeature.Installed) {
        Write-Log 'Installing Hyper-V feature...'
        $result = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
        if ($result.RestartNeeded -eq 'Yes') { $needReboot = $true }
    } else { Write-Log 'Hyper-V: already installed' }

    # ── 1.10 Import self-signed certificates ─────────────────
    Write-Log '1.10 Import self-signed certificates'
    # Download script from S3 first (Phase 3 not yet run on fresh VM)
    $importScript = Join-Path $Script:Config.ScriptsDir 'Import-Certificates.ps1'
    if (-not (Test-Path $importScript)) {
        Write-Log '  Fetching Import-Certificates.ps1 from S3...'
        Get-S3Object -Key $Script:Config.S3KeysExtra.ImportCerts -OutFile $importScript | Out-Null
    }
    if (Test-Path $importScript) {
        & $importScript -CertsDir $Script:Config.CertsDir 2>&1 | ForEach-Object { Write-Log "  certs: $_" }
    } else {
        Write-LogWarn 'Import-Certificates.ps1 not found — skipping cert import'
    }

    # ── 1.11 Enable WinRM (remote PowerShell) ────────────────
    Write-Log '1.11 Enable WinRM for remote PowerShell'
    # Download script from S3 first (Phase 3 not yet run on fresh VM)
    $winrmScript = Join-Path $Script:Config.ScriptsDir 'Enable-RemotePowerShell.ps1'
    if (-not (Test-Path $winrmScript)) {
        Write-Log '  Fetching Enable-RemotePowerShell.ps1 from S3...'
        Get-S3Object -Key $Script:Config.S3KeysExtra.EnableRemotePS -OutFile $winrmScript | Out-Null
    }
    if (Test-Path $winrmScript) {
        & $winrmScript 2>&1 | ForEach-Object { Write-Log "  winrm: $_" }
    } else {
        Write-LogWarn 'Enable-RemotePowerShell.ps1 not found — skipping WinRM setup'
    }

    # ── 1.12 Enable RDP audit policy ─────────────────────────
    Write-Log '1.12 Enable RDP logon audit policy'
    auditpol /set /subcategory:"Logon" /success:enable /failure:enable 2>$null
    Write-Log 'Logon audit policy enabled'

    # ── Mark + dispatch ──────────────────────────────────────
    Set-PhaseMarker $Script:Config.Phase1Marker
    Write-Log '========== PHASE 1 COMPLETE =========='

    if ($needReboot) {
        Invoke-Be1Reboot -Reason 'Phase 1 complete — Windows features require reboot'
    } else {
        Write-Log 'No reboot needed, continuing to Phase 2...'
        Invoke-Phase2
    }
}
