#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Be1 Post-Install Script — GitLab Runner Golden Image (Docker Executor, Windows)

.DESCRIPTION
    Executed by VMware Aria (Be1) on a freshly provisioned Windows Server 2019 VM.
    Produces a fully operational GitLab Runner registered at Group level.

    Three-phase execution with two reboots:
      Phase 1: System prep, services, env vars, dirs, Windows features → REBOOT
      Phase 2: daemon.json, Docker binaries, dockerd service → REBOOT
      Phase 3: Docker verify, runner install, registration, maintenance, validation

    All binaries from MinIO bucket "gitlab-runner-golden" via AWS Sig V4.
    All container images from Harbor project "golden-image".

.NOTES
    Target OS:       Windows Server 2019 LTSC (Build 17763)
    GitLab:          16.7.10-ee (self-managed, self-signed cert)
    Runner:          16.7.0
    Docker:          25.0.15 (raw docker.exe + dockerd.exe)
    Executor:        docker-windows (process isolation)

    Disk layout expected:
      C: (100 GB) — OS, runner binary, tools
      E: (1 TB)   — Docker data-root, pagefile, builds, cache
#>

# ============================================================
# CONFIGURATION
# ============================================================

$Script:Config = @{
    # --- MinIO S3 ---
    MinioEndpoint    = 'https://kayhut-minio.com:9000'
    MinioBucket      = 'gitlab-runner-golden'
    MinioAccessKey   = 'YOUR_ACCESS_KEY_HERE'
    MinioSecretKey   = 'YOUR_SECRET_KEY_HERE'
    MinioRegion      = 'us-east-1'

    # --- GitLab ---
    GitLabUrl        = 'https://gitlab.kayhut.com'

    # --- Harbor ---
    HarborUrl        = 'harbor.kayhut.com'
    HarborUser       = ''
    HarborPass       = ''

    # --- Paths (C: drive — OS, binaries, tools) ---
    RunnerDir        = 'C:\GitLab-Runner'
    RunnerBin        = 'C:\GitLab-Runner\gitlab-runner.exe'
    ConfigToml       = 'C:\GitLab-Runner\config.toml'
    LogsDir          = 'C:\GitLab-Runner\logs'
    ScriptsDir       = 'C:\GitLab-Runner\scripts'
    GitDir           = 'C:\GitLab-Runner\git'
    ToolsDir         = 'C:\Tools'
    SysInternalsDir  = 'C:\Tools\SysInternals'
    DockerConfigDir  = 'C:\ProgramData\docker\config'
    DaemonJson       = 'C:\ProgramData\docker\config\daemon.json'
    DockerDir        = 'C:\Program Files\Docker'

    # --- Paths (E: drive preferred — resolved at runtime below) ---
    BuildsDir        = $null
    CacheDir         = $null
    DockerDataRoot   = $null

    # --- Phase Markers ---
    Phase1Marker     = 'C:\GitLab-Runner\.phase1_complete'
    Phase2Marker     = 'C:\GitLab-Runner\.phase2_complete'

    # --- Thresholds ---
    StaleMinutes     = 60
    PagefileMaxMB    = 32768

    # --- Runner defaults ---
    ConcurrentJobs   = 2
    CheckInterval    = 3

    # --- MinIO object keys (only files actually downloaded) ---
    S3Keys = @{
        RunnerBin    = 'binaries/gitlab-runner-16.7.0-windows-amd64.exe'
        DockerExe    = 'binaries/docker/docker.exe'
        DockerdExe   = 'binaries/docker/dockerd.exe'
        MinGitZip    = 'binaries/git/MinGit-2.43.0-64-bit.zip'
        WinRarExe    = 'tools/winrar-x64-701.exe'
        NssmZip      = 'tools/nssm-2.24.zip'
        ProcExp      = 'tools/sysinternals/procexp64.exe'
        ProcMon      = 'tools/sysinternals/Procmon64.exe'
        Handle       = 'tools/sysinternals/handle64.exe'
        PsToolsZip   = 'tools/sysinternals/PSTools.zip'
        HealthCheck  = 'scripts/health-check.ps1'
        DiskMonitor  = 'scripts/disk-monitor.ps1'
        DockerWdog   = 'scripts/docker-watchdog.ps1'
        KillStale    = 'scripts/kill-stale-containers.ps1'
        RegTasks     = 'scripts/Register-ScheduledTasks.ps1'
    }

    # --- Pre-pull images ---
    PrePullImages = @(
        'harbor.kayhut.com/golden-image/gitlab-runner-helper:x86_64-v16.7.0-servercore1809',
        'harbor.kayhut.com/golden-image/servercore:ltsc2019',
        'harbor.kayhut.com/golden-image/windows:ltsc2019'
    )

    HelperImage = 'harbor.kayhut.com/golden-image/gitlab-runner-helper:x86_64-v16.7.0-servercore1809'

    InsecureRegistries = @(
        'harbor.kayhut.com',
        'gitlab.kayhut.com:5050',
        'artifactory-prod'
    )

    # --- Services to disable ---
    DisableServices = @(
        'WSearch', 'Spooler', 'Fax', 'WerSvc', 'DiagTrack', 'SysMain',
        'wuauserv', 'BITS', 'RemoteRegistry', 'MapsBroker', 'lfsvc',
        'RetailDemo', 'WMPNetworkSvc', 'XblAuthManager', 'XblGameSave',
        'XboxNetApiSvc', 'TabletInputService'
    )
}

# ============================================================
# RESOLVE DATA DRIVE (E: preferred, C: fallback)
# ============================================================

$Script:DataDrive = if (Test-Path 'E:\') { 'E:' } else { 'C:' }

$Script:Config.BuildsDir     = "$Script:DataDrive\GitLab-Runner\builds"
$Script:Config.CacheDir      = "$Script:DataDrive\GitLab-Runner\cache"
$Script:Config.DockerDataRoot = "$Script:DataDrive\docker-data"

# ============================================================
# TLS BYPASS — Guard against re-add on Be1 re-run
# ============================================================

if (-not ([System.Management.Automation.PSTypeName]'TrustAllCerts').Type) {
    Add-Type -TypeDefinition @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts {
    public static void Enable() {
        ServicePointManager.ServerCertificateValidationCallback =
            delegate { return true; };
        ServicePointManager.SecurityProtocol =
            SecurityProtocolType.Tls12 | SecurityProtocolType.Tls11 | SecurityProtocolType.Tls;
    }
}
"@
}

[TrustAllCerts]::Enable()

# ============================================================
# LOGGING
# ============================================================

$Script:LogFile = 'C:\GitLab-Runner\logs\install.log'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    $logDir = Split-Path $Script:LogFile -Parent
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
    $line | Out-File -FilePath $Script:LogFile -Append -Encoding UTF8
    Write-Output $line
}

function Write-LogError { param([string]$Message) Write-Log -Message $Message -Level 'ERROR' }
function Write-LogWarn  { param([string]$Message) Write-Log -Message $Message -Level 'WARN' }

# ============================================================
# SHARED HELPERS
# ============================================================

function Get-S3Object {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$OutFile
    )

    $endpoint  = $Script:Config.MinioEndpoint
    $bucket    = $Script:Config.MinioBucket
    $accessKey = $Script:Config.MinioAccessKey
    $secretKey = $Script:Config.MinioSecretKey
    $region    = $Script:Config.MinioRegion

    $uri      = [System.Uri]$endpoint
    $hostName = $uri.Host
    if ($uri.Port -ne 443 -and $uri.Port -ne 80) { $hostName = "$($uri.Host):$($uri.Port)" }

    $now       = [DateTime]::UtcNow
    $dateStamp = $now.ToString('yyyyMMdd')
    $amzDate   = $now.ToString('yyyyMMddTHHmmssZ')

    $encodedKey       = ($Key -split '/' | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
    $canonicalUri     = "/$bucket/$encodedKey"
    $payloadHash      = 'UNSIGNED-PAYLOAD'
    $canonicalHeaders = "host:$hostName`nx-amz-content-sha256:$payloadHash`nx-amz-date:$amzDate`n"
    $signedHeaders    = 'host;x-amz-content-sha256;x-amz-date'
    $canonicalRequest = "GET`n$canonicalUri`n`n$canonicalHeaders`n$signedHeaders`n$payloadHash"

    $credentialScope = "$dateStamp/$region/s3/aws4_request"
    $canonicalHash   = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($canonicalRequest)
        )
    ).Replace('-','').ToLower()

    $stringToSign = "AWS4-HMAC-SHA256`n$amzDate`n$credentialScope`n$canonicalHash"

    function HmacSHA256([byte[]]$key, [string]$data) {
        $hmac = New-Object System.Security.Cryptography.HMACSHA256
        $hmac.Key = $key
        return $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($data))
    }

    $kSecret   = [System.Text.Encoding]::UTF8.GetBytes("AWS4$secretKey")
    $kDate     = HmacSHA256 $kSecret  $dateStamp
    $kRegion   = HmacSHA256 $kDate    $region
    $kService  = HmacSHA256 $kRegion  's3'
    $kSigning  = HmacSHA256 $kService 'aws4_request'
    $signature = [System.BitConverter]::ToString((HmacSHA256 $kSigning $stringToSign)).Replace('-','').ToLower()

    $authHeader = "AWS4-HMAC-SHA256 Credential=$accessKey/$credentialScope, SignedHeaders=$signedHeaders, Signature=$signature"
    $url = "$endpoint/$bucket/$Key"

    $outDir = Split-Path $OutFile -Parent
    if (-not (Test-Path $outDir)) { New-Item -Path $outDir -ItemType Directory -Force | Out-Null }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('Authorization', $authHeader)
            $wc.Headers.Add('x-amz-content-sha256', $payloadHash)
            $wc.Headers.Add('x-amz-date', $amzDate)
            $wc.DownloadFile($url, $OutFile)
            if (Test-Path $OutFile) {
                $size = (Get-Item $OutFile).Length
                Write-Log "Downloaded $Key → $OutFile ($size bytes)"
                return $true
            }
        }
        catch {
            Write-LogWarn "Download attempt $attempt/3 failed for $Key : $_"
            Start-Sleep -Seconds ($attempt * 5)
        }
    }
    Write-LogError "FAILED to download $Key after 3 attempts"
    return $false
}

function Test-PEBinary {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        return ($bytes.Length -ge 2 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A)
    }
    catch {
        Write-LogWarn "PE validation failed for $Path : $_"
        return $false
    }
}

function Install-S3Binary {
    param([string]$S3Key, [string]$DestPath, [string]$Label)
    if (Test-PEBinary $DestPath) { Write-Log "$Label already present"; return $true }
    $ok = Get-S3Object -Key $S3Key -OutFile $DestPath
    if ($ok -and (Test-PEBinary $DestPath)) { Write-Log "$Label downloaded and validated"; return $true }
    Write-LogError "FATAL: $Label — download or validation failed"
    return $false
}

function Install-S3Archive {
    param([string]$S3Key, [string]$DestDir, [string]$TestFile, [string]$Label)
    if ($TestFile -and (Test-Path $TestFile)) { Write-Log "$Label already present"; return $true }
    $zipPath = Join-Path $env:TEMP "s3_$(Split-Path $S3Key -Leaf)"
    $ok = Get-S3Object -Key $S3Key -OutFile $zipPath
    if ($ok) {
        Expand-Archive -Path $zipPath -DestinationPath $DestDir -Force
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Write-Log "$Label extracted to $DestDir"
        return $true
    }
    Write-LogError "FATAL: $Label — download failed"
    return $false
}

function Wait-ServiceRunning {
    param([string]$Name, [int]$TimeoutSeconds = 120, [int]$PollSeconds = 10, [switch]$StartIfStopped)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { return $true }
        if ($StartIfStopped -and $svc -and $svc.Status -ne 'Running') {
            Start-Service -Name $Name -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds $PollSeconds
    }
    return $false
}

function Get-DnsServer {
    $servers = @()
    try {
        $adapters = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.ServerAddresses.Count -gt 0 }
        foreach ($a in $adapters) { $servers += $a.ServerAddresses }
        $servers = $servers | Select-Object -Unique | Select-Object -First 2
    }
    catch { Write-LogWarn "DNS auto-detect failed: $_" }
    return $servers
}

function Invoke-Be1Reboot {
    param([string]$Reason = 'GitLab Runner setup phase complete')
    Write-Log "Requesting reboot: $Reason"
    shutdown.exe /r /t 15 /c $Reason /d p:4:1
    Write-Output 'POWER_ON'
    exit 3010
}

function Set-PhaseMarker {
    param([string]$Path)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    Get-Date -Format 'o' | Out-File -FilePath $Path -Encoding UTF8 -Force
    Write-Log "Phase marker set: $Path"
}

function Test-PhaseComplete {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $age = (Get-Date) - (Get-Item $Path).LastWriteTime
    if ($age.TotalMinutes -gt $Script:Config.StaleMinutes) {
        Write-LogWarn "Phase marker $Path is stale ($([int]$age.TotalMinutes) min). Re-running phase."
        Remove-Item $Path -Force
        return $false
    }
    return $true
}

# ============================================================
# PHASE 1: System Prep + Windows Features
# ============================================================

function Invoke-Phase1 {
    Write-Log '========== PHASE 1: System Preparation =========='

    # 1.1 Register Event Log source
    Write-Log '1.1 Register Event Log source'
    New-EventLog -LogName Application -Source 'GitLabRunner' -ErrorAction SilentlyContinue

    # 1.2 Disable unnecessary services
    Write-Log '1.2 Disable unnecessary Windows services'
    foreach ($svc in $Script:Config.DisableServices) {
        $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($service) {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
            Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
        }
    }
    Write-Log "Processed $($Script:Config.DisableServices.Count) services"

    # 1.3 Power plan
    Write-Log '1.3 Set High Performance power plan'
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c

    # 1.4 Page file (registry method, data drive, capped)
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

    # 1.5 Network tuning + long paths
    Write-Log '1.5 Network tuning + long paths'
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1 -Type DWord
    netsh int tcp set global autotuninglevel=normal 2>$null
    netsh int ipv4 set dynamicport tcp start=10000 num=55535 2>$null
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'TcpTimedWaitDelay' -Value 30 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name 'MaxCacheEntryTtlLimit' -Value 86400 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -Value 2 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name 'MinAnimate' -Value '0' -ErrorAction SilentlyContinue

    # 1.6 Environment variables + PATH (refresh current process immediately)
    Write-Log '1.6 Set environment variables'
    [System.Environment]::SetEnvironmentVariable('GIT_SSL_NO_VERIFY', 'true', 'Machine')
    [System.Environment]::SetEnvironmentVariable('DOTNET_CLI_TELEMETRY_OPTOUT', '1', 'Machine')
    [System.Environment]::SetEnvironmentVariable('DOTNET_NOLOGO', '1', 'Machine')
    $currentPath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
    foreach ($p in @('C:\Program Files\Docker', 'C:\GitLab-Runner\git\cmd', 'C:\Tools', 'C:\GitLab-Runner')) {
        if ($currentPath -notlike "*$p*") { $currentPath = "$currentPath;$p" }
    }
    [System.Environment]::SetEnvironmentVariable('PATH', $currentPath, 'Machine')
    $env:PATH = $currentPath

    # 1.7 Create directory structure
    Write-Log '1.7 Create directory structure'
    foreach ($d in @(
        $Script:Config.RunnerDir, $Script:Config.BuildsDir, $Script:Config.CacheDir,
        $Script:Config.LogsDir, $Script:Config.ScriptsDir, $Script:Config.GitDir,
        $Script:Config.ToolsDir, $Script:Config.SysInternalsDir,
        $Script:Config.DockerConfigDir, $Script:Config.DockerDir
    )) {
        if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
    }

    # 1.8 Event Log sizes
    Write-Log '1.8 Event Log sizes'
    wevtutil sl Application /ms:104857600 2>$null
    wevtutil sl System /ms:104857600 2>$null
    wevtutil sl Security /ms:52428800 2>$null

    # 1.9 Install Windows Features
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

    Set-PhaseMarker $Script:Config.Phase1Marker
    Write-Log '========== PHASE 1 COMPLETE =========='

    if ($needReboot) {
        Invoke-Be1Reboot -Reason 'Phase 1 complete — Windows features require reboot'
    } else {
        Write-Log 'No reboot needed, continuing to Phase 2...'
        Invoke-Phase2
    }
}

# ============================================================
# PHASE 2: Docker daemon.json + Docker Binary Install
# ============================================================

function Invoke-Phase2 {
    Write-Log '========== PHASE 2: Docker Installation =========='

    # 2.1 Write daemon.json
    Write-Log '2.1 Write daemon.json'
    $dnsServers = Get-DnsServer
    $daemonConfig = [ordered]@{
        'insecure-registries'      = $Script:Config.InsecureRegistries
        'storage-driver'           = 'windowsfilter'
        'log-driver'               = 'json-file'
        'log-opts'                 = [ordered]@{ 'max-size' = '50m'; 'max-file' = '5' }
        'exec-opts'                = @('isolation=process')
        'max-concurrent-downloads' = 5
        'max-concurrent-uploads'   = 3
        'max-download-attempts'    = 5
        'debug'                    = $false
        'data-root'                = $Script:Config.DockerDataRoot
        'group'                    = 'docker-users'
    }
    if ($dnsServers.Count -gt 0) { $daemonConfig['dns'] = @($dnsServers) }
    $daemonConfig | ConvertTo-Json -Depth 4 | Out-File -FilePath $Script:Config.DaemonJson -Encoding UTF8 -Force
    Write-Log "daemon.json written (data-root: $($Script:Config.DockerDataRoot))"
    if (-not (Test-Path $Script:Config.DockerDataRoot)) {
        New-Item -Path $Script:Config.DockerDataRoot -ItemType Directory -Force | Out-Null
    }

    # 2.2 Download Docker binaries
    Write-Log '2.2 Download Docker binaries'
    $dockerExe  = Join-Path $Script:Config.DockerDir 'docker.exe'
    $dockerdExe = Join-Path $Script:Config.DockerDir 'dockerd.exe'
    if (-not (Install-S3Binary -S3Key $Script:Config.S3Keys.DockerExe  -DestPath $dockerExe  -Label 'docker.exe'))  { exit 1 }
    if (-not (Install-S3Binary -S3Key $Script:Config.S3Keys.DockerdExe -DestPath $dockerdExe -Label 'dockerd.exe')) { exit 1 }

    # 2.3 Register dockerd as Windows service
    Write-Log '2.3 Register Docker service'
    $dockerSvc = Get-Service docker -ErrorAction SilentlyContinue
    if ($dockerSvc -and $dockerSvc.Status -eq 'Running') {
        Write-Log 'Docker service already running'
    } else {
        if ($dockerSvc) {
            Write-Log 'Removing stale Docker service...'
            Stop-Service docker -Force -ErrorAction SilentlyContinue
            & $dockerdExe --unregister-service 2>&1 | ForEach-Object { Write-Log "  unregister: $_" }
            Start-Sleep -Seconds 3
        }
        & $dockerdExe --register-service 2>&1 | ForEach-Object { Write-Log "  register: $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-LogError 'FATAL: dockerd --register-service failed'
            exit 1
        }
        Write-Log 'dockerd registered as Windows service'
        Start-Service docker -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 10
    }

    Set-PhaseMarker $Script:Config.Phase2Marker
    Write-Log '========== PHASE 2 COMPLETE =========='

    $dockerSvc = Get-Service docker -ErrorAction SilentlyContinue
    if (-not $dockerSvc -or $dockerSvc.Status -ne 'Running') {
        Invoke-Be1Reboot -Reason 'Phase 2 complete — Docker installed, reboot required'
    } else {
        Write-Log 'Docker running, continuing to Phase 3...'
        Invoke-Phase3
    }
}

# ============================================================
# PHASE 3: Docker Verify, Runner, Maintenance, Validation
# ============================================================

function Invoke-Phase3 {
    Write-Log '========== PHASE 3: Runner Setup & Configuration =========='

    # 3.1 Verify Docker daemon
    Write-Log '3.1 Verify Docker daemon'
    $dockerReady = $false
    for ($i = 1; $i -le 12; $i++) {
        try {
            $svc = Get-Service docker -ErrorAction SilentlyContinue
            if (-not $svc -or $svc.Status -ne 'Running') {
                Write-Log "Docker not running, starting... (attempt $i)"
                Start-Service docker -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 10
                continue
            }
            $null = docker info 2>&1
            if ($LASTEXITCODE -eq 0) { $dockerReady = $true; Write-Log 'Docker daemon is ready'; break }
        }
        catch { Write-LogWarn "Docker check attempt $i failed: $_" }
        Write-Log "Waiting for Docker... (attempt $i/12)"
        Start-Sleep -Seconds 10
    }
    if (-not $dockerReady) { Write-LogError 'FATAL: Docker not ready after 2 minutes'; exit 1 }

    $dockerVersion   = docker version --format '{{.Server.Version}}' 2>$null
    $dockerIsolation = docker info --format '{{.Isolation}}' 2>$null
    Write-Log "Docker: version=$dockerVersion isolation=$dockerIsolation"

    # 3.2 Defender exclusions
    Write-Log '3.2 Defender exclusions'
    foreach ($p in @('C:\GitLab-Runner', 'C:\ProgramData\docker', 'C:\Program Files\Docker',
                     $Script:Config.BuildsDir, $Script:Config.CacheDir, $Script:Config.DockerDataRoot)) {
        try { Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue }
        catch { Write-LogWarn "Defender path exclusion failed: $p" }
    }
    foreach ($p in @('gitlab-runner.exe', 'dockerd.exe', 'docker.exe', 'containerd.exe', 'git.exe')) {
        try { Add-MpPreference -ExclusionProcess $p -ErrorAction SilentlyContinue }
        catch { Write-LogWarn "Defender process exclusion failed: $p" }
    }

    # 3.3 MinGit
    Write-Log '3.3 MinGit'
    Install-S3Archive -S3Key $Script:Config.S3Keys.MinGitZip `
        -DestDir $Script:Config.GitDir `
        -TestFile (Join-Path $Script:Config.GitDir 'cmd\git.exe') `
        -Label 'MinGit' | Out-Null

    # 3.4 GitLab Runner binary
    Write-Log '3.4 GitLab Runner binary'
    if (-not (Install-S3Binary -S3Key $Script:Config.S3Keys.RunnerBin -DestPath $Script:Config.RunnerBin -Label 'GitLab Runner')) { exit 1 }

    # 3.5 Pre-pull Harbor images
    Write-Log '3.5 Pre-pull container images'
    if ($Script:Config.HarborUser -and $Script:Config.HarborPass) {
        Write-Log 'Logging into Harbor...'
        $Script:Config.HarborPass | docker login $Script:Config.HarborUrl -u $Script:Config.HarborUser --password-stdin 2>&1 |
            ForEach-Object { Write-Log "  docker login: $_" }
    }
    foreach ($image in $Script:Config.PrePullImages) {
        Write-Log "Pulling: $image"
        docker pull $image 2>&1 | ForEach-Object { Write-Log "  $_" }
        if ($LASTEXITCODE -ne 0) { Write-LogWarn "Failed to pull $image — will pull on first job" }
    }

    # 3.6 Write config.toml
    Write-Log '3.6 Write config.toml'
    $runnerToken = $env:GITLAB_RUNNER_TOKEN
    if (-not $runnerToken) { $runnerToken = [System.Environment]::GetEnvironmentVariable('GITLAB_RUNNER_TOKEN', 'Machine') }
    if (-not $runnerToken) { Write-LogError 'FATAL: GITLAB_RUNNER_TOKEN not found'; exit 1 }

    $hostname   = $env:COMPUTERNAME
    $dnsServers = Get-DnsServer
    $dnsLine = ''
    if ($dnsServers.Count -ge 2) { $dnsLine = "    dns = [`"$($dnsServers[0])`", `"$($dnsServers[1])`"]" }
    elseif ($dnsServers.Count -eq 1) { $dnsLine = "    dns = [`"$($dnsServers[0])`"]" }

    $buildsVol = "$($Script:Config.BuildsDir -replace '\\','\\'):C:\\builds"
    $cacheVol  = "$($Script:Config.CacheDir  -replace '\\','\\'):C:\\cache"

    $configContent = @"
# GitLab Runner Configuration — Auto-generated
# Host: $hostname | Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

concurrent = $($Script:Config.ConcurrentJobs)
check_interval = $($Script:Config.CheckInterval)
shutdown_timeout = 300
log_level = "info"

[[runners]]
  name = "runner-$hostname"
  url = "$($Script:Config.GitLabUrl)"
  token = "$runnerToken"
  executor = "docker-windows"
  tls-verify = false
  environment = ["GIT_SSL_NO_VERIFY=true", "DOCKER_TLS_CERTDIR="]

  [runners.docker]
    image = "harbor.kayhut.com/golden-image/servercore:ltsc2019"
    helper_image = "$($Script:Config.HelperImage)"
    isolation = "process"
    pull_policy = ["if-not-present"]
    tls_verify = false
    privileged = false
    shm_size = 268435456
    volumes = ["$buildsVol", "$cacheVol"]
$dnsLine
    allowed_images = []
    allowed_services = []
    wait_for_services_timeout = 30
    disable_cache = false

  [runners.cache]
    Type = ""
"@
    $configContent | Out-File -FilePath $Script:Config.ConfigToml -Encoding UTF8 -Force
    Write-Log 'config.toml written'

    # 3.7 Register runner
    Write-Log '3.7 Register runner'
    & $Script:Config.RunnerBin register `
        --non-interactive `
        --url $Script:Config.GitLabUrl `
        --token $runnerToken `
        --executor docker-windows `
        --docker-image "harbor.kayhut.com/golden-image/servercore:ltsc2019" `
        --tls-ca-file "" `
        --name "runner-$hostname" 2>&1 | ForEach-Object { Write-Log "  register: $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-LogWarn 'Runner registration non-zero. Config.toml pre-written — runner may still work.'
    }
    $configContent | Out-File -FilePath $Script:Config.ConfigToml -Encoding UTF8 -Force

    # 3.8 Install runner service (idempotent)
    Write-Log '3.8 Install runner service'
    & $Script:Config.RunnerBin stop 2>$null
    & $Script:Config.RunnerBin uninstall 2>$null
    Start-Sleep -Seconds 2
    & $Script:Config.RunnerBin install 2>&1 | ForEach-Object { Write-Log "  install: $_" }
    & $Script:Config.RunnerBin start  2>&1 | ForEach-Object { Write-Log "  start: $_" }
    if (Wait-ServiceRunning -Name 'gitlab-runner' -TimeoutSeconds 30 -PollSeconds 3) {
        Write-Log 'GitLab Runner service is RUNNING'
    } else {
        Write-LogError 'GitLab Runner service failed to start'
    }

    # 3.9 Deploy maintenance scripts
    Write-Log '3.9 Deploy maintenance scripts'
    foreach ($s in @(
        @{ Key = $Script:Config.S3Keys.HealthCheck; File = 'health-check.ps1' },
        @{ Key = $Script:Config.S3Keys.DiskMonitor;  File = 'disk-monitor.ps1' },
        @{ Key = $Script:Config.S3Keys.DockerWdog;   File = 'docker-watchdog.ps1' },
        @{ Key = $Script:Config.S3Keys.KillStale;    File = 'kill-stale-containers.ps1' },
        @{ Key = $Script:Config.S3Keys.RegTasks;     File = 'Register-ScheduledTasks.ps1' }
    )) {
        Get-S3Object -Key $s.Key -OutFile (Join-Path $Script:Config.ScriptsDir $s.File) | Out-Null
    }

    # 3.10 Register scheduled tasks
    Write-Log '3.10 Register scheduled tasks'
    $regScript = Join-Path $Script:Config.ScriptsDir 'Register-ScheduledTasks.ps1'
    if (Test-Path $regScript) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $regScript 2>&1 |
            ForEach-Object { Write-Log "  tasks: $_" }
    } else {
        Write-LogWarn 'Register-ScheduledTasks.ps1 not found — inline fallback'
        Register-InlineScheduledTask
    }

    # 3.11 Deploy tools
    Write-Log '3.11 Deploy tools'
    $winrarExe = Join-Path $Script:Config.ToolsDir 'winrar-x64-701.exe'
    if (Get-S3Object -Key $Script:Config.S3Keys.WinRarExe -OutFile $winrarExe) {
        Start-Process -FilePath $winrarExe -ArgumentList '/s' -Wait -NoNewWindow -ErrorAction SilentlyContinue
        Remove-Item $winrarExe -Force -ErrorAction SilentlyContinue
        Write-Log 'WinRAR installed'
    }
    if (Install-S3Archive -S3Key $Script:Config.S3Keys.NssmZip -DestDir $Script:Config.ToolsDir -TestFile '' -Label 'NSSM') {
        $nssmExe = Get-ChildItem -Path $Script:Config.ToolsDir -Recurse -Filter 'nssm.exe' |
                   Where-Object { $_.FullName -like '*win64*' } | Select-Object -First 1
        if ($nssmExe) { Copy-Item $nssmExe.FullName (Join-Path $Script:Config.ToolsDir 'nssm.exe') -Force }
    }
    foreach ($si in @(
        @{ Key = $Script:Config.S3Keys.ProcExp; File = 'procexp64.exe' },
        @{ Key = $Script:Config.S3Keys.ProcMon; File = 'Procmon64.exe' },
        @{ Key = $Script:Config.S3Keys.Handle;  File = 'handle64.exe' }
    )) { Get-S3Object -Key $si.Key -OutFile (Join-Path $Script:Config.SysInternalsDir $si.File) | Out-Null }
    Install-S3Archive -S3Key $Script:Config.S3Keys.PsToolsZip -DestDir $Script:Config.SysInternalsDir -TestFile '' -Label 'PSTools' | Out-Null
    Write-Log 'Tools deployed'

    # 3.12 Final validation
    Write-Log '========== FINAL VALIDATION =========='
    Invoke-FinalValidation
    Write-Log '========== PHASE 3 COMPLETE — RUNNER IS OPERATIONAL =========='
}

# ============================================================
# INLINE SCHEDULED TASKS (fallback)
# ============================================================

function Register-InlineScheduledTask {
    $sd = $Script:Config.ScriptsDir
    $pr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $forever = New-TimeSpan -Days 3650
    $tasks = @(
        @{ Name='Docker-Image-Prune';         Trigger=(New-ScheduledTaskTrigger -Daily -At '03:00');                                                                         Action="-NoProfile -Command `"docker image prune -a --filter 'until=168h' --force 2>&1 | Out-File C:\GitLab-Runner\logs\image-prune.log -Append`"" },
        @{ Name='Docker-Container-Cleanup';   Trigger=(New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Hours 4) -RepetitionDuration $forever);  Action="-NoProfile -Command `"docker container prune --force 2>&1 | Out-File C:\GitLab-Runner\logs\container-prune.log -Append`"" },
        @{ Name='Docker-Stale-Container-Kill';Trigger=(New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Hours 2) -RepetitionDuration $forever);  Action="-NoProfile -ExecutionPolicy Bypass -File `"$sd\kill-stale-containers.ps1`"" },
        @{ Name='Docker-Volume-Prune';        Trigger=(New-ScheduledTaskTrigger -Daily -At '03:30');                                                                         Action="-NoProfile -Command `"docker volume prune --force 2>&1 | Out-File C:\GitLab-Runner\logs\volume-prune.log -Append`"" },
        @{ Name='Docker-BuildCache-Prune';    Trigger=(New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '04:00');                                                      Action="-NoProfile -Command `"docker builder prune --all --force 2>&1 | Out-File C:\GitLab-Runner\logs\buildcache-prune.log -Append`"" },
        @{ Name='Runner-Workspace-Cleanup';   Trigger=(New-ScheduledTaskTrigger -Daily -At '04:00');                                                                         Action="-NoProfile -Command `"Get-ChildItem '$($Script:Config.BuildsDir)' -Directory | Where-Object { `$_.LastWriteTime -lt (Get-Date).AddDays(-3) } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue`"" },
        @{ Name='Disk-Space-Monitor';         Trigger=(New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration $forever);Action="-NoProfile -ExecutionPolicy Bypass -File `"$sd\disk-monitor.ps1`"" },
        @{ Name='Docker-Daemon-Watchdog';     Trigger=(New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration $forever); Action="-NoProfile -ExecutionPolicy Bypass -File `"$sd\docker-watchdog.ps1`"" },
        @{ Name='Runner-Service-Watchdog';    Trigger=(New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration $forever); Action="-NoProfile -Command `"if ((Get-Service gitlab-runner -ErrorAction SilentlyContinue).Status -ne 'Running') { Start-Service gitlab-runner; Write-EventLog -LogName Application -Source 'GitLabRunner' -EventId 9004 -EntryType Warning -Message 'Runner restarted.' }`"" },
        @{ Name='Log-Rotation';               Trigger=(New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '05:00');                                                      Action="-NoProfile -Command `"Get-ChildItem 'C:\GitLab-Runner\logs\*.log' | Where-Object { `$_.Length -gt 50MB } | ForEach-Object { Move-Item `$_.FullName (`$_.FullName + '.old') -Force }`"" }
    )
    foreach ($t in $tasks) {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $t.Action
        Register-ScheduledTask -TaskName $t.Name -Action $action -Trigger $t.Trigger -Principal $pr -Force | Out-Null
    }
    Write-Log "Registered $($tasks.Count) scheduled tasks (inline)"
}

# ============================================================
# FINAL VALIDATION
# ============================================================

function Invoke-FinalValidation {
    $pass = 0; $fail = 0; $total = 0
    function Check {
        param([string]$Name, [scriptblock]$Test)
        $script:total++
        try {
            if (& $Test) { Write-Log "  [PASS] $Name"; $script:pass++ }
            else          { Write-Log "  [FAIL] $Name" -Level 'WARN'; $script:fail++ }
        }
        catch { Write-Log "  [FAIL] $Name — $_" -Level 'WARN'; $script:fail++ }
    }

    Check 'OS Build = 17763'            { [System.Environment]::OSVersion.Version.Build -eq 17763 }
    Check 'Containers feature'          { (Get-WindowsFeature Containers).Installed }
    Check 'Hyper-V feature'             { (Get-WindowsFeature Hyper-V).Installed }
    Check 'Docker service running'      { (Get-Service docker -ErrorAction SilentlyContinue).Status -eq 'Running' }
    Check 'Docker version = 25.0'       { (docker version --format '{{.Server.Version}}' 2>$null) -match '25\.0' }
    Check 'Docker isolation = process'  { (docker info --format '{{.Isolation}}' 2>$null) -eq 'process' }
    Check 'Runner binary valid'         { Test-PEBinary $Script:Config.RunnerBin }
    Check 'Runner service running'      { (Get-Service gitlab-runner -ErrorAction SilentlyContinue).Status -eq 'Running' }
    Check 'Runner verify (is alive)'    { (& $Script:Config.RunnerBin verify 2>&1 | Out-String) -match 'is alive' }
    Check 'Git available'               { Test-Path (Join-Path $Script:Config.GitDir 'cmd\git.exe') }
    Check 'GIT_SSL_NO_VERIFY set'       { [System.Environment]::GetEnvironmentVariable('GIT_SSL_NO_VERIFY','Machine') -eq 'true' }
    Check 'Defender exclusions'         { (Get-MpPreference).ExclusionPath -contains 'C:\GitLab-Runner' }
    Check 'Helper image present'        { (docker images $Script:Config.HelperImage --format '{{.Tag}}' 2>$null) -match 'v16.7.0' }
    Check 'Scheduled tasks (>=8)'       { (Get-ScheduledTask | Where-Object { $_.TaskName -match '^(Docker|Runner|Disk|Log)-' } | Measure-Object).Count -ge 8 }
    Check 'Power plan = High Perf'      { (powercfg /getactivescheme) -match '8c5e7fda' }
    Check 'Long paths enabled'          { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem').LongPathsEnabled -eq 1 }
    Check 'Disk free >= 50 GB'          { [math]::Round((Get-PSDrive C).Free / 1GB) -ge 50 }

    Write-Log "Validation: $pass/$total passed, $fail failed"
    if ($fail -gt 0) {
        Write-EventLog -LogName Application -Source 'GitLabRunner' -EventId 9010 -EntryType Warning `
            -Message "Validation: $fail of $total checks failed."
    } else {
        Write-EventLog -LogName Application -Source 'GitLabRunner' -EventId 9011 -EntryType Information `
            -Message "Validation: ALL $total checks passed."
    }
}

# ============================================================
# MAIN — Phase Detection & Dispatch
# ============================================================

try {
    Write-Log '============================================'
    Write-Log "Install-GitLabRunner.ps1 — START"
    Write-Log "Host: $env:COMPUTERNAME | OS: $([System.Environment]::OSVersion.VersionString)"
    Write-Log "Data drive: $Script:DataDrive"
    Write-Log '============================================'

    if (Test-PhaseComplete $Script:Config.Phase2Marker) {
        Write-Log 'Phase 2 marker → Phase 3'
        Invoke-Phase3
    }
    elseif (Test-PhaseComplete $Script:Config.Phase1Marker) {
        Write-Log 'Phase 1 marker → Phase 2'
        Invoke-Phase2
    }
    else {
        Write-Log 'No markers → Phase 1'
        Invoke-Phase1
    }
}
catch {
    Write-LogError "UNHANDLED EXCEPTION: $($_.Exception.Message)"
    Write-LogError "Stack trace: $($_.ScriptStackTrace)"
    exit 1
}
