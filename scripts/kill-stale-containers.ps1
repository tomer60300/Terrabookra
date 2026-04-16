<#
.SYNOPSIS
    Kill stale containers — removes CI containers stuck longer than 4 hours.

.DESCRIPTION
    Runs every 2 hours via scheduled task (Docker-Stale-Container-Kill).
    Parses `docker ps` output to detect containers running longer than
    the threshold and force-kills them.

.NOTES
    Log: C:\GitLab-Runner\logs\stale-containers.log
#>

$ErrorActionPreference = 'Continue'
$maxAgeHours = 4
$logFile     = 'C:\GitLab-Runner\logs\stale-containers.log'

$logDir = Split-Path $logFile -Parent
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

# ── Find and kill stale containers ───────────────────────────
$killed = 0
$containers = docker ps --format "{{.ID}} {{.RunningFor}}" 2>$null

foreach ($line in $containers) {
    if ($line -match '^(\w+)\s+.*?(\d+)\s+hours') {
        $id    = $Matches[1]
        $hours = [int]$Matches[2]

        if ($hours -ge $maxAgeHours) {
            docker kill $id 2>&1 | Out-Null
            $killed++
            "$(Get-Date -Format o) Killed container $id (running ${hours}h)" |
                Out-File $logFile -Append -Encoding UTF8
        }
    }
}

if ($killed -gt 0) {
    Write-EventLog -LogName Application -Source 'GitLabRunner' -EventId 9012 -EntryType Warning `
        -Message "Killed $killed stale container(s) running longer than ${maxAgeHours} hours."
}
