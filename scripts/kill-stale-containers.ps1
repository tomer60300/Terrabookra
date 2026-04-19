<#
.SYNOPSIS
    Kill stale containers — removes CI containers stuck longer than 4 hours.

.DESCRIPTION
    Runs every 2 hours via scheduled task (Docker-Stale-Container-Kill).
    Parses `docker ps` output to detect containers running longer than
    the threshold and force-kills them.

.PARAMETER MaxAgeHours
    Hours before a running container is considered stale. Default: 4

.PARAMETER LogFile
    Path to the stale containers log file. Default: C:\GitLab-Runner\logs\stale-containers.log

.NOTES
    Event IDs:
      9012 — Stale containers killed
#>

param(
    [int]$MaxAgeHours = 4,
    [string]$LogFile  = 'C:\GitLab-Runner\logs\stale-containers.log'
)

$ErrorActionPreference = 'Continue'

$logDir = Split-Path $LogFile -Parent
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

# ── Find and kill stale containers ───────────────────────────
$killed = 0
$containers = docker ps --format "{{.ID}} {{.RunningFor}}" 2>$null

foreach ($line in $containers) {
    if ($line -match '^(\w+)\s+.*?(\d+)\s+hours') {
        $id    = $Matches[1]
        $hours = [int]$Matches[2]

        if ($hours -ge $MaxAgeHours) {
            docker kill $id 2>&1 | Out-Null
            $killed++
            "$(Get-Date -Format o) Killed container $id (running ${hours}h)" |
                Out-File $LogFile -Append -Encoding UTF8
        }
    }
}

if ($killed -gt 0) {
    Write-EventLog -LogName Application -Source 'GitLabRunner' -EventId 9012 -EntryType Warning `
        -Message "Killed $killed stale container(s) running longer than ${MaxAgeHours} hours."
}
