<#
.SYNOPSIS
    Disk space monitor -- emergency prune when disk is critically low.

.DESCRIPTION
    Runs every 30 minutes via scheduled task (Disk-Space-Monitor).
    Checks BOTH C: and the data drive (if different).
    Thresholds:
      < 10 GB  -> CRITICAL: full docker system prune --all
      < 20 GB  -> WARNING:  event log only (no auto action)

.PARAMETER LogFile
    Path to the disk monitor log file. Default: C:\GitLab-Runner\logs\disk-monitor.log

.PARAMETER DataDrive
    Drive letter for Docker data/builds (e.g. 'E'). If omitted, auto-detects E: or defaults to C.

.NOTES
    Event IDs:
      9001 -- Critical disk space, emergency prune executed
      9002 -- Low disk space warning
#>

param(
    [string]$LogFile   = 'C:\GitLab-Runner\logs\disk-monitor.log',
    [string]$DataDrive = ''
)

$ErrorActionPreference = 'Continue'
$source = 'GitLabRunner'

$logDir = Split-Path $LogFile -Parent
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

# Auto-detect data drive if not specified
if (-not $DataDrive) {
    $DataDrive = if (Test-Path 'E:\') { 'E' } else { 'C' }
}
$DataDrive = $DataDrive.TrimEnd(':')

# Build list of drives to check (unique)
$drives = @('C')
if ($DataDrive -ne 'C') { $drives += $DataDrive }

$pruneNeeded = $false
$logLines = @()

foreach ($drv in $drives) {
    $freeGB = [math]::Round((Get-PSDrive $drv).Free / 1GB, 1)

    if ($freeGB -lt 10) {
        $pruneNeeded = $true
        $logLines += "CRITICAL ${drv}: DiskFree=${freeGB}GB"
    }
    elseif ($freeGB -lt 20) {
        Write-EventLog -LogName Application -Source $source -EventId 9002 -EntryType Warning `
            -Message "WARNING: ${drv}: drive has ${freeGB} GB free."
        $logLines += "WARNING ${drv}: DiskFree=${freeGB}GB"
    }
    else {
        $logLines += "OK ${drv}: DiskFree=${freeGB}GB"
    }
}

if ($pruneNeeded) {
    docker system prune --all --force 2>&1 | Out-Null

    # Re-check after prune
    $afterParts = @()
    foreach ($drv in $drives) {
        $freeAfter = [math]::Round((Get-PSDrive $drv).Free / 1GB, 1)
        $afterParts += "${drv}:=${freeAfter}GB"
    }
    $afterMsg = $afterParts -join ', '
    Write-EventLog -LogName Application -Source $source -EventId 9001 -EntryType Error `
        -Message "CRITICAL: Emergency prune executed. After prune: $afterMsg"

    "$(Get-Date -Format o) CRITICAL prune executed | $($logLines -join ' | ') | After: $afterMsg" |
        Out-File $LogFile -Append -Encoding UTF8
}
else {
    "$(Get-Date -Format o) $($logLines -join ' | ')" |
        Out-File $LogFile -Append -Encoding UTF8
}
