<#
.SYNOPSIS
    Health check -- monitors Docker, Runner service, disk space, and stale containers.

.DESCRIPTION
    Runs every 5 minutes via scheduled task (Disk-Space-Monitor-HealthCheck).
    Writes status line to health-check.log and fires Windows Event Log entries
    for any degraded component so the watchdog scripts can react.

.PARAMETER LogFile
    Path to the health check log file. Default: C:\GitLab-Runner\logs\health-check.log

.PARAMETER DataDrive
    Drive letter for Docker data/builds (e.g. 'E'). If omitted, auto-detects E: or defaults to C.

.NOTES
    Event IDs:
      9005 -- Docker daemon unresponsive
      9006 -- GitLab Runner service not running
      9007 -- Low disk space (< 20 GB)
      9008 -- Stale containers detected (> 4 h)
#>

param(
    [string]$LogFile   = 'C:\GitLab-Runner\logs\health-check.log',
    [string]$DataDrive = ''
)

$ErrorActionPreference = 'Continue'
$source = 'GitLabRunner'

# -- Docker daemon ------------------------------------------------
$dockerOk = $false
try {
    $null = docker info 2>&1
    if ($LASTEXITCODE -eq 0) { $dockerOk = $true }
}
catch { <# handled below #> }

if (-not $dockerOk) {
    Write-EventLog -LogName Application -Source $source -EventId 9005 -EntryType Error `
        -Message 'Health check: Docker daemon is NOT responsive.'
}

# -- GitLab Runner service ----------------------------------------
$runnerSvc = Get-Service gitlab-runner -ErrorAction SilentlyContinue
$runnerOk  = $runnerSvc -and $runnerSvc.Status -eq 'Running'

if (-not $runnerOk) {
    $status = if ($runnerSvc) { $runnerSvc.Status } else { 'NOT FOUND' }
    Write-EventLog -LogName Application -Source $source -EventId 9006 -EntryType Error `
        -Message "Health check: GitLab Runner service is NOT running. Status: $status"
}

# -- Disk space (C: + data drive) ---------------------------------
if (-not $DataDrive) {
    $DataDrive = if (Test-Path 'E:\') { 'E' } else { 'C' }
}
$DataDrive = $DataDrive.TrimEnd(':')

$drives = @('C')
if ($DataDrive -ne 'C') { $drives += $DataDrive }

$diskParts = @()
$diskOk = $true
foreach ($drv in $drives) {
    $freeGB = [math]::Round((Get-PSDrive $drv).Free / 1GB, 1)
    $diskParts += "${drv}:=${freeGB}GB"
    if ($freeGB -lt 20) {
        $diskOk = $false
        Write-EventLog -LogName Application -Source $source -EventId 9007 -EntryType Warning `
            -Message "Health check: Low disk space. ${drv}: drive has ${freeGB} GB free."
    }
}
$diskInfo = $diskParts -join ', '

# -- Stale containers (running > 4 hours) -------------------------
$staleCount = 0
$now = Get-Date
$containerIds = docker ps -q 2>$null
foreach ($id in $containerIds) {
    if (-not $id) { continue }
    try {
        $startedStr = docker inspect --format '{{.State.StartedAt}}' $id 2>$null
        if (-not $startedStr) { continue }
        $startedStr = $startedStr -replace '(\.\d{7})\d+', '$1'
        $startedAt = [datetime]::Parse($startedStr).ToLocalTime()
        if (($now - $startedAt).TotalHours -ge 4) { $staleCount++ }
    } catch {}
}

if ($staleCount -gt 0) {
    Write-EventLog -LogName Application -Source $source -EventId 9008 -EntryType Warning `
        -Message "Health check: $staleCount stale container(s) running longer than 4 hours."
}

# -- Summary line -------------------------------------------------
$status = if ($dockerOk -and $runnerOk -and $diskOk -and $staleCount -eq 0) {
    'HEALTHY'
} else {
    'DEGRADED'
}

$logDir = Split-Path $LogFile -Parent
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

"$(Get-Date -Format o) [$status] Docker=$dockerOk Runner=$runnerOk Disk=($diskInfo) StaleContainers=$staleCount" |
    Out-File $LogFile -Append -Encoding UTF8
