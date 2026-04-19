<#
.SYNOPSIS
    Health check — monitors Docker, Runner service, disk space, and stale containers.

.DESCRIPTION
    Runs every 5 minutes via scheduled task (Disk-Space-Monitor-HealthCheck).
    Writes status line to health-check.log and fires Windows Event Log entries
    for any degraded component so the watchdog scripts can react.

.PARAMETER LogFile
    Path to the health check log file. Default: C:\GitLab-Runner\logs\health-check.log

.NOTES
    Event IDs:
      9005 — Docker daemon unresponsive
      9006 — GitLab Runner service not running
      9007 — Low disk space (< 20 GB)
      9008 — Stale containers detected (> 4 h)
#>

param(
    [string]$LogFile = 'C:\GitLab-Runner\logs\health-check.log'
)

$ErrorActionPreference = 'Continue'
$source = 'GitLabRunner'

# ── Docker daemon ────────────────────────────────────────────
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

# ── GitLab Runner service ────────────────────────────────────
$runnerSvc = Get-Service gitlab-runner -ErrorAction SilentlyContinue
$runnerOk  = $runnerSvc -and $runnerSvc.Status -eq 'Running'

if (-not $runnerOk) {
    $status = if ($runnerSvc) { $runnerSvc.Status } else { 'NOT FOUND' }
    Write-EventLog -LogName Application -Source $source -EventId 9006 -EntryType Error `
        -Message "Health check: GitLab Runner service is NOT running. Status: $status"
}

# ── Disk space ───────────────────────────────────────────────
$freeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)

if ($freeGB -lt 20) {
    Write-EventLog -LogName Application -Source $source -EventId 9007 -EntryType Warning `
        -Message "Health check: Low disk space. C: drive has ${freeGB} GB free."
}

# ── Stale containers (running > 4 hours) ─────────────────────
$staleCount = 0
$containers = docker ps --format "{{.ID}} {{.RunningFor}}" 2>$null
foreach ($line in $containers) {
    if ($line -match '^(\w+)\s+.*?(\d+)\s+hours') {
        if ([int]$Matches[2] -ge 4) { $staleCount++ }
    }
}

if ($staleCount -gt 0) {
    Write-EventLog -LogName Application -Source $source -EventId 9008 -EntryType Warning `
        -Message "Health check: $staleCount stale container(s) running longer than 4 hours."
}

# ── Summary line ─────────────────────────────────────────────
$status = if ($dockerOk -and $runnerOk -and $freeGB -ge 20 -and $staleCount -eq 0) {
    'HEALTHY'
} else {
    'DEGRADED'
}

$logDir = Split-Path $LogFile -Parent
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

"$(Get-Date -Format o) [$status] Docker=$dockerOk Runner=$runnerOk DiskFree=${freeGB}GB StaleContainers=$staleCount" |
    Out-File $LogFile -Append -Encoding UTF8
