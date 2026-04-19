<#
.SYNOPSIS
    Runner log collector -- bundles all logs + diagnostics into a single zip.

.DESCRIPTION
    One command to collect everything you need when debugging a failed job
    or investigating a runner issue. Creates a timestamped zip in the output
    directory containing:

    1. Install log (install.log)
    2. CI job logs (logs\jobs\*)
    3. Network probe logs (logs\network\*)
    4. RDP audit logs (logs\rdp\*)
    5. Maintenance logs (health-check, disk-monitor, docker-watchdog, stale-containers, prune logs)
    6. Docker diagnostics (docker info, docker ps, docker images, docker system df, daemon.json)
    7. Runner diagnostics (config.toml, gitlab-runner verify, service status)
    8. Windows Event Log export (Application log, last 24 hours by default)
    9. System info snapshot (OS, RAM, disk, uptime, network adapters)
    10. Golden image version stamp (if present)

    Run manually or via PSRemoting from your admin PC:
      Invoke-Command -ComputerName runner01 -ScriptBlock { C:\GitLab-Runner\scripts\Export-RunnerLogs.ps1 }

.PARAMETER OutputDir
    Where to write the zip. Default: C:\GitLab-Runner\logs

.PARAMETER RunnerDir
    Runner base directory. Default: C:\GitLab-Runner

.PARAMETER DaemonJson
    Path to Docker daemon.json. Default: C:\ProgramData\docker\config\daemon.json

.PARAMETER HoursBack
    How many hours of Event Log to export. Default: 24.

.PARAMETER JobId
    Optional -- if provided, only collects logs relevant to that job timeframe.

.OUTPUTS
    Full path to the created zip file.

.NOTES
    File: scripts/Export-RunnerLogs.ps1
#>

param(
    [string]$OutputDir  = 'C:\GitLab-Runner\logs',
    [string]$RunnerDir  = 'C:\GitLab-Runner',
    [string]$DaemonJson = 'C:\ProgramData\docker\config\daemon.json',
    [int]$HoursBack     = 24,
    [string]$JobId      = ''
)

$ErrorActionPreference = 'Continue'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$hostname  = $env:COMPUTERNAME
$tempDir   = Join-Path $env:TEMP "runner-logs-$timestamp"
$zipName   = "runner-logs-${hostname}-${timestamp}.zip"
$zipPath   = Join-Path $OutputDir $zipName

# Derived paths from RunnerDir
$logsDir    = Join-Path $RunnerDir 'logs'
$runnerBin  = Join-Path $RunnerDir 'gitlab-runner.exe'
$configToml = Join-Path $RunnerDir 'config.toml'
$versionFile = Join-Path $RunnerDir '.golden-version'

# -- Create temp collection directory -------------------------
New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

# -- 1. Install log ------------------------------------------
$installLog = Join-Path $logsDir 'install.log'
if (Test-Path $installLog) {
    Copy-Item $installLog (Join-Path $tempDir 'install.log') -Force
}

# -- 2-4. Daily logs (jobs, network, rdp) --------------------
foreach ($sub in @('jobs', 'network', 'rdp')) {
    $srcDir = Join-Path $logsDir $sub
    if (Test-Path $srcDir) {
        $destSub = Join-Path $tempDir $sub
        New-Item -Path $destSub -ItemType Directory -Force | Out-Null
        # Copy last 3 days of logs
        Get-ChildItem $srcDir -File | Where-Object {
            $_.LastWriteTime -gt (Get-Date).AddDays(-3)
        } | Copy-Item -Destination $destSub -Force
    }
}

# -- 5. Maintenance logs -------------------------------------
$maintDir = Join-Path $tempDir 'maintenance'
New-Item -Path $maintDir -ItemType Directory -Force | Out-Null
$maintFiles = @(
    'health-check.log', 'disk-monitor.log', 'docker-watchdog.log',
    'stale-containers.log', 'image-prune.log', 'container-prune.log',
    'volume-prune.log', 'buildcache-prune.log'
)
foreach ($f in $maintFiles) {
    $src = Join-Path $logsDir $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $maintDir $f) -Force }
}

# -- 6. Docker diagnostics -----------------------------------
$dockerDir = Join-Path $tempDir 'docker'
New-Item -Path $dockerDir -ItemType Directory -Force | Out-Null

try { docker info 2>&1        | Out-File (Join-Path $dockerDir 'docker-info.txt') -Encoding UTF8 } catch {}
try { docker ps -a 2>&1       | Out-File (Join-Path $dockerDir 'docker-ps.txt') -Encoding UTF8 } catch {}
try { docker images 2>&1      | Out-File (Join-Path $dockerDir 'docker-images.txt') -Encoding UTF8 } catch {}
try { docker system df 2>&1   | Out-File (Join-Path $dockerDir 'docker-disk.txt') -Encoding UTF8 } catch {}

if (Test-Path $DaemonJson) { Copy-Item $DaemonJson (Join-Path $dockerDir 'daemon.json') -Force }

# -- 7. Runner diagnostics -----------------------------------
$runnerOutDir = Join-Path $tempDir 'runner'
New-Item -Path $runnerOutDir -ItemType Directory -Force | Out-Null

if (Test-Path $configToml) { Copy-Item $configToml (Join-Path $runnerOutDir 'config.toml') -Force }

try {
    & $runnerBin verify 2>&1 |
        Out-File (Join-Path $runnerOutDir 'runner-verify.txt') -Encoding UTF8
} catch {}

$svcStatus = Get-Service gitlab-runner, docker -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType | Format-Table -AutoSize | Out-String
$svcStatus | Out-File (Join-Path $runnerOutDir 'services.txt') -Encoding UTF8

# -- 8. Windows Event Log (Application, last N hours) --------
$evtDir = Join-Path $tempDir 'eventlog'
New-Item -Path $evtDir -ItemType Directory -Force | Out-Null

try {
    $since = (Get-Date).AddHours(-$HoursBack)
    Get-WinEvent -FilterHashtable @{
        LogName   = 'Application'
        StartTime = $since
    } -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -eq 'GitLabRunner' -or $_.LevelDisplayName -in 'Error','Warning' } |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Export-Csv (Join-Path $evtDir 'application-events.csv') -NoTypeInformation -Encoding UTF8
} catch {}

# -- 9. System info snapshot ----------------------------------
$sysInfo = [ordered]@{
    Hostname     = $hostname
    Timestamp    = Get-Date -Format 'o'
    OS           = [System.Environment]::OSVersion.VersionString
    OSBuild      = [System.Environment]::OSVersion.Version.Build
    Uptime       = ((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToString('d\.hh\:mm\:ss')
    RamGB        = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    DiskFreeC_GB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
}
# E: drive if present
if (Test-Path 'E:\') {
    $sysInfo.DiskFreeE_GB = [math]::Round((Get-PSDrive E -ErrorAction SilentlyContinue).Free / 1GB, 1)
}
# Network adapters
$adapters = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -ne '127.0.0.1' } |
    Select-Object InterfaceAlias, IPAddress | Format-Table -AutoSize | Out-String

$sysInfo.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" } |
    Out-File (Join-Path $tempDir 'system-info.txt') -Encoding UTF8
$adapters | Out-File (Join-Path $tempDir 'system-info.txt') -Append -Encoding UTF8

# -- 10. Golden image version stamp ---------------------------
if (Test-Path $versionFile) {
    Copy-Item $versionFile (Join-Path $tempDir 'golden-version.txt') -Force
}

# -- Create zip -----------------------------------------------
if (-not (Test-Path $OutputDir)) { New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null }

Compress-Archive -Path "$tempDir\*" -DestinationPath $zipPath -Force

# Cleanup temp
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

$size = [math]::Round((Get-Item $zipPath).Length / 1KB, 1)
Write-Output "Log bundle created: $zipPath ($size KB)"
Write-Output $zipPath
