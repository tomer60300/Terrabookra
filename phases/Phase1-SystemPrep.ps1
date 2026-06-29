<#
.SYNOPSIS
    Phase 1 -- System preparation, services, environment, Windows features.

.DESCRIPTION
    Called by Bootstrap-GitLabRunner.ps1 when no phase markers exist.
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
    1.9  Install Windows Features (Containers always, Hyper-V iff host
         exposes nested virtualization; a marker file persists the skip
         decision across the upcoming reboot)
    1.10 Import self-signed certificates
    1.11 Enable OpenSSH server (remote control plane; replaces the prior
         WinRM step which was blocked by domain GPO)
    1.12 Enable RDP audit policy

    Reboots via Be1 if features required it, otherwise continues to Phase 2.

.NOTES
    File: phases/Phase1-SystemPrep.ps1
    Requires: lib/Config.ps1, lib/Common.ps1 (dot-sourced by orchestrator)
#>

function Invoke-Phase1 {
    Write-Log '========== PHASE 1: System Preparation =========='

    # -- 0.5 Environment preflight (fail fast on a bad host) --
    Write-Log '0.5 Environment preflight (Assert-Environment)'
    $preScript = Join-Path $PSScriptRoot '..\scripts\Assert-Environment.ps1'
    if (-not (Test-Path $preScript)) {
        $preScript = Join-Path $Script:Config.ScriptsDir 'Assert-Environment.ps1'
        if (-not (Test-Path $preScript)) {
            if (-not (Copy-RepoFile -RelPath $Script:Config.S3KeysExtra.AssertEnv -OutFile $preScript)) {
                Write-LogError 'FATAL: could not stage Assert-Environment.ps1 from repo -- preflight is mandatory'; exit 1
            }
        }
    }
    $preResult = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $preScript 2>&1
    $preExit   = $LASTEXITCODE
    $preResult | ForEach-Object { Write-Log "  preflight: $_" }
    if ($preExit -ne 0) { Write-LogError 'FATAL: environment preflight failed -- aborting'; exit 1 }

    # -- 1.0 Pre-flight build-input validation ----------------
    # Packer model: artifacts come from the uploaded repo tree (Git LFS), images
    # from the GitLab Container Registry. Validate those, not MinIO/Harbor.
    Write-Log '1.0 Pre-flight build-input validation (repo artifacts + GitLab registry)'
    $depScript = Join-Path $PSScriptRoot '..\validation\Test-BuildInputs.ps1'
    if (-not (Test-Path $depScript)) {
        Write-LogError "FATAL: Test-BuildInputs.ps1 not found at $depScript -- pre-flight is mandatory"
        exit 1
    }
    # Subprocess -- the script uses `exit`, which would otherwise kill this phase.
    # -SkipRegistry: the registry isn't needed until Phase 3 (pre-pull), and that
    # pull is the real registry gate. Don't fail Phase 1 on a registry blip.
    $depResult = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $depScript -SkipRegistry 2>&1
    $depExit   = $LASTEXITCODE
    $depResult | ForEach-Object { Write-Log "  preflight: $_" }
    if ($depExit -ne 0) {
        Write-LogError "FATAL: build-input validation failed ($depExit) -- missing repo artifacts (Git LFS not materialized?)."
        exit 1
    }

    # -- 1.1 Event Log source ---------------------------------
    Write-Log '1.1 Register Event Log source'
    New-EventLog -LogName Application -Source 'GitLabRunner' -ErrorAction SilentlyContinue

    # -- 1.2 Disable unnecessary services ---------------------
    Write-Log '1.2 Disable unnecessary Windows services'
    foreach ($svc in $Script:Config.DisableServices) {
        $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($service) {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
            Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
        }
    }
    Write-Log "Processed $($Script:Config.DisableServices.Count) services"

    # -- 1.3 Power plan ---------------------------------------
    Write-Log '1.3 Set High Performance power plan'
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c

    # -- 1.4 Page file ----------------------------------------
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

    # -- 1.5 Network tuning + long paths ----------------------
    Write-Log '1.5 Network tuning + long paths'
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1 -Type DWord
    netsh int tcp set global autotuninglevel=normal 2>$null
    netsh int ipv4 set dynamicport tcp start=10000 num=55535 2>$null
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'TcpTimedWaitDelay' -Value 30 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name 'MaxCacheEntryTtlLimit' -Value 86400 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -Value 2 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name 'MinAnimate' -Value '0' -ErrorAction SilentlyContinue

    # -- 1.6 Environment variables + PATH ---------------------
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

    # -- 1.7 Directory structure ------------------------------
    Write-Log '1.7 Create directory structure'
    foreach ($d in @(
        $Script:Config.RunnerDir, $Script:Config.BuildsDir, $Script:Config.CacheDir,
        $Script:Config.LogsDir, $Script:Config.ScriptsDir, $Script:Config.GitDir,
        $Script:Config.ToolsDir, $Script:Config.SysInternalsDir,
        $Script:Config.DockerConfigDir, $Script:Config.DockerDir
    )) {
        if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
    }

    # -- 1.8 Event Log sizes ---------------------------------
    Write-Log '1.8 Event Log sizes'
    wevtutil sl Application /ms:104857600 2>$null
    wevtutil sl System /ms:104857600 2>$null
    wevtutil sl Security /ms:52428800 2>$null

    # -- 1.9 Windows Features ---------------------------------
    Write-Log '1.9 Install Windows Features (Containers, Hyper-V)'
    $needReboot = $false

    $containersFeature = Get-WindowsFeature -Name Containers
    if (-not $containersFeature.Installed) {
        Write-Log 'Installing Containers feature...'
        $result = Install-WindowsFeature -Name Containers
        if ($result.RestartNeeded -eq 'Yes') { $needReboot = $true }
    } else { Write-Log 'Containers: already installed' }

    # Hyper-V requires hardware virtualization (VT-x/AMD-V) exposed by the
    # hypervisor. On VMware, this is the per-VM "Expose hardware assisted
    # virtualization to the guest OS" setting (nested virt). When absent,
    # Install-WindowsFeature fails the prerequisite check. Process isolation
    # does NOT need Hyper-V, so we skip gracefully and the runner continues
    # on process isolation only -- writing a marker file so validation in
    # Phase 3 (different process after reboot) knows the skip was deliberate.
    $hypervFeature = Get-WindowsFeature -Name Hyper-V
    if ($hypervFeature.Installed) {
        Write-Log 'Hyper-V: already installed'
        if (Test-Path $Script:Config.HyperVSkippedMarker) {
            Remove-Item $Script:Config.HyperVSkippedMarker -Force -ErrorAction SilentlyContinue
        }
    } else {
        $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
        $vtExposed = [bool]$cpu.VirtualizationFirmwareEnabled -or [bool]$cpu.VMMonitorModeExtensions
        if (-not $vtExposed) {
            Write-LogWarn 'Hyper-V SKIPPED: CPU does not expose hardware virtualization (host-side nested-virt setting).'
            Write-LogWarn '  Runner will operate with docker-windows process isolation only (which does NOT need Hyper-V).'
            Write-LogWarn '  To enable Hyper-V isolation later: enable "Expose hardware assisted virtualization to the guest OS" on the VM in vSphere/Be1 template, then re-run this phase.'
            "skipped at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -- VT-x not exposed by host" |
                Out-File -FilePath $Script:Config.HyperVSkippedMarker -Encoding UTF8 -Force
        } else {
            Write-Log 'Installing Hyper-V feature...'
            $result = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
            if ($result.RestartNeeded -eq 'Yes') { $needReboot = $true }
            if (Test-Path $Script:Config.HyperVSkippedMarker) {
                Remove-Item $Script:Config.HyperVSkippedMarker -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # -- 1.10 Import self-signed certificates -----------------
    Write-Log '1.10 Import self-signed certificates'
    # Stage the script from the uploaded repo (Phase 3 not yet run on fresh VM).
    $importScript = Join-Path $Script:Config.ScriptsDir 'Import-Certificates.ps1'
    if (-not (Test-Path $importScript)) {
        Write-Log '  Staging Import-Certificates.ps1 from repo...'
        Copy-RepoFile -RelPath $Script:Config.S3KeysExtra.ImportCerts -OutFile $importScript | Out-Null
    }
    if (-not (Test-Path $importScript)) {
        Write-LogError 'FATAL: Import-Certificates.ps1 could not be staged from repo. Cert trust is required -- aborting before the Phase 1 marker.'
        exit 1
    }
    $global:LASTEXITCODE = 0
    & $importScript -CertsDir $Script:Config.CertsDir 2>&1 | ForEach-Object { Write-Log "  certs: $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-LogError "FATAL: Import-Certificates.ps1 exited $LASTEXITCODE -- aborting before the Phase 1 marker."
        exit 1
    }

    # -- 1.11 Enable OpenSSH (remote control plane) -----------
    # Replaces the prior WinRM step. WinRM is blocked at Kayhut by domain GPO
    # (Set-Service / Restart-Service on the WinRM service raise "Access is
    # denied" even from local admins). OpenSSH is installed from a portable
    # zip release of PowerShell/Win32-OpenSSH; no Add-WindowsCapability call,
    # no BITS, no internet -- works fully air-gapped.
    #
    # Auth model: AD password auth is the PRIMARY mechanism on a domain-joined
    # runner. sshd hands password attempts to the Windows logon stack which
    # validates against the domain controller. A public-key fallback is
    # optionally seeded from administrators_authorized_keys (skipped if the
    # file isn't staged in MinIO).
    Write-Log '1.11 Enable OpenSSH server (remote control plane)'

    # Stage zip + authorized_keys from the uploaded repo into C:\Tools\openssh\
    if (-not (Test-Path $Script:Config.OpenSshStageDir)) {
        New-Item -Path $Script:Config.OpenSshStageDir -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path $Script:Config.OpenSshZipLocal)) {
        Write-Log '  Staging OpenSSH-Win64.zip from repo...'
        Copy-RepoFile -RelPath $Script:Config.S3KeysExtra.OpenSshZip -OutFile $Script:Config.OpenSshZipLocal | Out-Null
    }
    if (-not (Test-Path $Script:Config.OpenSshZipLocal)) {
        Write-LogError 'FATAL: OpenSSH-Win64.zip could not be staged from repo. SSH is the remote control plane (WinRM is GPO-blocked) -- aborting before the Phase 1 marker.'
        exit 1
    }
    if (-not (Test-Path $Script:Config.OpenSshAuthKeysSource)) {
        Write-Log '  Staging administrators_authorized_keys from repo (optional)...'
        Copy-RepoFile -RelPath $Script:Config.S3KeysExtra.OpenSshAuthKeys -OutFile $Script:Config.OpenSshAuthKeysSource | Out-Null
    }

    # Stage the SSH-enable script
    $sshScript = Join-Path $Script:Config.ScriptsDir 'Enable-RemoteSSH.ps1'
    if (-not (Test-Path $sshScript)) {
        Write-Log '  Staging Enable-RemoteSSH.ps1 from repo...'
        Copy-RepoFile -RelPath $Script:Config.S3KeysExtra.EnableRemoteSSH -OutFile $sshScript | Out-Null
    }
    if (-not (Test-Path $sshScript)) {
        Write-LogError 'FATAL: Enable-RemoteSSH.ps1 could not be staged from repo. SSH is the remote control plane -- aborting before the Phase 1 marker.'
        exit 1
    }
    $global:LASTEXITCODE = 0
    & $sshScript `
        -OpenSshZip           $Script:Config.OpenSshZipLocal `
        -InstallDir           $Script:Config.OpenSshInstallDir `
        -AuthorizedKeysSource $Script:Config.OpenSshAuthKeysSource `
        -FirewallRuleName     $Script:Config.OpenSshFirewallRule `
        -AllowedADGroups      $Script:Config.OpenSshAllowedADGroups 2>&1 |
        ForEach-Object { Write-Log "  ssh: $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-LogError "FATAL: Enable-RemoteSSH.ps1 exited $LASTEXITCODE (sshd failed to start?) -- aborting before the Phase 1 marker."
        exit 1
    }

    # -- 1.12 Enable RDP audit policy -------------------------
    Write-Log '1.12 Enable RDP logon audit policy'
    auditpol /set /subcategory:"Logon" /success:enable /failure:enable 2>$null
    Write-Log 'Logon audit policy enabled'

    # -- Mark + complete --------------------------------------
    Set-PhaseMarker $Script:Config.Phase1Marker
    Write-Log '========== PHASE 1 COMPLETE =========='

    # Packer owns sequencing: it issues a `windows-restart` after this phase and
    # then runs Invoke-Phase 2. The phase no longer self-reboots or self-chains.
    if ($needReboot) { Write-Log 'Windows features require a reboot -- Packer windows-restart will follow.' }
    else             { Write-Log 'No reboot strictly required; Packer still restarts before Phase 2.' }
}
