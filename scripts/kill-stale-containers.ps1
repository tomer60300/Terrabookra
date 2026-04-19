<#
.SYNOPSIS
    Kill stale containers -- removes CI containers stuck longer than threshold.

.DESCRIPTION
    Runs every 2 hours via scheduled task (Docker-Stale-Container-Kill).
    Uses docker inspect StartedAt timestamp for precise age calculation.
    Force-kills containers running longer than the threshold.

.PARAMETER MaxAgeHours
    Hours before a running container is considered stale. Default: 4

.PARAMETER LogFile
    Path to the stale containers log file. Default: C:\GitLab-Runner\logs\stale-containers.log

.NOTES
    Event IDs:
      9012 -- Stale containers killed
#>

param(
    [int]$MaxAgeHours = 4,
    [string]$LogFile  = 'C:\GitLab-Runner\logs\stale-containers.log'
)

$ErrorActionPreference = 'Continue'

$logDir = Split-Path $LogFile -Parent
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

# -- Find and kill stale containers -------------------------------
$killed = 0
$now = Get-Date
$containerIds = docker ps -q 2>$null

foreach ($id in $containerIds) {
    if (-not $id) { continue }
    try {
        $startedStr = docker inspect --format '{{.State.StartedAt}}' $id 2>$null
        if (-not $startedStr) { continue }

        # Docker returns ISO 8601: 2026-04-19T10:30:00.123456789Z
        # Trim nanosecond precision to parse with .NET (max 7 fractional digits)
        $startedStr = $startedStr -replace '(\.\d{7})\d+', '$1'
        $startedAt = [datetime]::Parse($startedStr).ToLocalTime()
        $ageHours  = ($now - $startedAt).TotalHours

        if ($ageHours -ge $MaxAgeHours) {
            docker kill $id 2>&1 | Out-Null
            $killed++
            $ageRound = [math]::Round($ageHours, 1)
            "$(Get-Date -Format o) Killed container $id (running ${ageRound}h, started: $startedStr)" |
                Out-File $LogFile -Append -Encoding UTF8
        }
    } catch {
        # Container may have exited between ps and inspect -- skip
    }
}

if ($killed -gt 0) {
    Write-EventLog -LogName Application -Source 'GitLabRunner' -EventId 9012 -EntryType Warning `
        -Message "Killed $killed stale container(s) running longer than ${MaxAgeHours} hours."
}
