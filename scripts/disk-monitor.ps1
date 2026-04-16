<#
.SYNOPSIS
    Disk space monitor — emergency prune when disk is critically low.

.DESCRIPTION
    Runs every 30 minutes via scheduled task (Disk-Space-Monitor).
    Thresholds:
      < 10 GB  → CRITICAL: full docker system prune --all
      < 20 GB  → WARNING:  event log only (no auto action)

.NOTES
    Event IDs:
      9001 — Critical disk space, emergency prune executed
      9002 — Low disk space warning

    Log: C:\GitLab-Runner\logs\disk-monitor.log
#>

$ErrorActionPreference = 'Continue'
$source  = 'GitLabRunner'
$logFile = 'C:\GitLab-Runner\logs\disk-monitor.log'

$logDir = Split-Path $logFile -Parent
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

# ── Check disk space ─────────────────────────────────────────
$freeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)

if ($freeGB -lt 10) {
    # CRITICAL — aggressive prune
    docker system prune --all --force 2>&1 | Out-Null

    $freeAfter = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
    Write-EventLog -LogName Application -Source $source -EventId 9001 -EntryType Error `
        -Message "CRITICAL: Disk was ${freeGB} GB. Emergency prune executed. Now ${freeAfter} GB free."

    "$(Get-Date -Format o) CRITICAL DiskFree=${freeGB}GB -> pruned -> ${freeAfter}GB" |
        Out-File $logFile -Append -Encoding UTF8
}
elseif ($freeGB -lt 20) {
    Write-EventLog -LogName Application -Source $source -EventId 9002 -EntryType Warning `
        -Message "WARNING: Disk space is ${freeGB} GB. Consider manual cleanup."

    "$(Get-Date -Format o) WARNING DiskFree=${freeGB}GB" |
        Out-File $logFile -Append -Encoding UTF8
}
else {
    "$(Get-Date -Format o) OK DiskFree=${freeGB}GB" |
        Out-File $logFile -Append -Encoding UTF8
}
