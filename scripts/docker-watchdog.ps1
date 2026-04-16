<#
.SYNOPSIS
    Docker daemon watchdog — restarts Docker + Runner if the daemon is unresponsive.

.DESCRIPTION
    Runs every 5 minutes via scheduled task (Docker-Daemon-Watchdog).
    If `docker info` fails, restarts the Docker service and then the
    GitLab Runner service (which loses its connection when Docker drops).

.NOTES
    Event IDs:
      9003 — Docker daemon restarted
      9009 — Docker restart failed

    Log: C:\GitLab-Runner\logs\docker-watchdog.log
#>

$ErrorActionPreference = 'Continue'
$source  = 'GitLabRunner'
$logFile = 'C:\GitLab-Runner\logs\docker-watchdog.log'

$logDir = Split-Path $logFile -Parent
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

# ── Check Docker ─────────────────────────────────────────────
$dockerOk = $false
try {
    $null = docker info 2>&1
    if ($LASTEXITCODE -eq 0) { $dockerOk = $true }
}
catch { <# fall through to restart #> }

if ($dockerOk) { return }

# ── Restart Docker ───────────────────────────────────────────
Write-EventLog -LogName Application -Source $source -EventId 9003 -EntryType Error `
    -Message 'Docker daemon unresponsive. Restarting Docker and Runner services.'

Restart-Service docker -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 15

# Verify recovery
$null = docker info 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-EventLog -LogName Application -Source $source -EventId 9009 -EntryType Error `
        -Message 'Docker restart FAILED — daemon still unresponsive after restart.'
    "$(Get-Date -Format o) Docker restart FAILED" |
        Out-File $logFile -Append -Encoding UTF8
    return
}

# ── Restart Runner (lost Docker connection) ──────────────────
Restart-Service gitlab-runner -Force -ErrorAction SilentlyContinue

"$(Get-Date -Format o) Docker daemon restarted successfully. Runner restarted." |
    Out-File $logFile -Append -Encoding UTF8
