<#
.SYNOPSIS
    Kill stale containers -- removes CI containers stuck longer than threshold.

.DESCRIPTION
    Runs every 2 hours via scheduled task (Docker-Stale-Container-Kill).
    Parses `docker ps` RunningFor field to detect containers running longer
    than the threshold and force-kills them. Handles hours, days, and weeks.

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
$containers = docker ps --format "{{.ID}} {{.RunningFor}}" 2>$null

foreach ($line in $containers) {
    if ($line -match '^(\w+)\s+(.+)$') {
        $id     = $Matches[1]
        $runFor = $Matches[2]

        # Convert RunningFor text to approximate hours
        $totalHours = 0
        if ($runFor -match '(\d+)\s+weeks?')  { $totalHours += [int]$Matches[1] * 168 }
        if ($runFor -match '(\d+)\s+days?')   { $totalHours += [int]$Matches[1] * 24 }
        if ($runFor -match '(\d+)\s+hours?')  { $totalHours += [int]$Matches[1] }

        if ($totalHours -ge $MaxAgeHours) {
            docker kill $id 2>&1 | Out-Null
            $killed++
            "$(Get-Date -Format o) Killed container $id (running ~${totalHours}h, raw: $runFor)" |
                Out-File $LogFile -Append -Encoding UTF8
        }
    }
}

if ($killed -gt 0) {
    Write-EventLog -LogName Application -Source 'GitLabRunner' -EventId 9012 -EntryType Warning `
        -Message "Killed $killed stale container(s) running longer than ${MaxAgeHours} hours."
}
