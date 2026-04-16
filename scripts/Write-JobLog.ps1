<#
.SYNOPSIS
    Job wrapper logger — logs CI job start/end to a daily file on the host.

.DESCRIPTION
    Called from config.toml as pre_build_script (action=start) and
    post_build_script (action=end).

    Writes a structured log line for each job event to a daily log file.
    History auto-rotated: files older than 30 days are deleted.

    Usage in config.toml:
      pre_build_script  = "powershell -NoProfile -File C:\\GitLab-Runner\\scripts\\Write-JobLog.ps1 -Action start"
      post_build_script = "powershell -NoProfile -File C:\\GitLab-Runner\\scripts\\Write-JobLog.ps1 -Action end"

.PARAMETER Action
    'start' or 'end'

.NOTES
    File: scripts/Write-JobLog.ps1
    Log: C:\GitLab-Runner\logs\jobs\jobs-YYYY-MM-DD.log

    Environment variables used (set by GitLab Runner):
      CI_JOB_ID, CI_JOB_NAME, CI_PROJECT_NAME, CI_PIPELINE_ID,
      CI_PIPELINE_SOURCE, GITLAB_USER_LOGIN, CI_JOB_STATUS (post only)
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet('start', 'end')]
    [string]$Action
)

$ErrorActionPreference = 'Continue'
$logDir     = 'C:\GitLab-Runner\logs\jobs'
$maxAgeDays = 30

if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

# ── Gather job info from CI environment variables ────────────
$now         = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
$today       = Get-Date -Format 'yyyy-MM-dd'
$jobId       = $env:CI_JOB_ID       ?? 'unknown'
$jobName     = $env:CI_JOB_NAME     ?? 'unknown'
$project     = $env:CI_PROJECT_NAME ?? 'unknown'
$pipelineId  = $env:CI_PIPELINE_ID  ?? 'unknown'
$source      = $env:CI_PIPELINE_SOURCE ?? 'unknown'
$user        = $env:GITLAB_USER_LOGIN  ?? 'unknown'
$status      = $env:CI_JOB_STATUS      ?? 'n/a'
$hostname    = $env:COMPUTERNAME

$logFile = Join-Path $logDir "jobs-$today.log"

# ── Write log line ───────────────────────────────────────────
if ($Action -eq 'start') {
    # Store start time for duration calculation
    $startFile = Join-Path $env:TEMP "job-start-$jobId.txt"
    $now | Out-File $startFile -Force -Encoding UTF8

    $line = "[$now] [START] Job=$jobName ID=$jobId Pipeline=$pipelineId Project=$project User=$user Source=$source Host=$hostname"
}
else {
    # Calculate duration
    $duration = 'unknown'
    $startFile = Join-Path $env:TEMP "job-start-$jobId.txt"
    if (Test-Path $startFile) {
        try {
            $startTime = Get-Date (Get-Content $startFile -Raw).Trim()
            $elapsed   = (Get-Date) - $startTime
            $duration  = '{0:hh\:mm\:ss\.fff}' -f $elapsed
        }
        catch { $duration = 'parse-error' }
        Remove-Item $startFile -Force -ErrorAction SilentlyContinue
    }

    $line = "[$now] [END]   Job=$jobName ID=$jobId Pipeline=$pipelineId Project=$project User=$user Status=$status Duration=$duration Host=$hostname"
}

$line | Out-File $logFile -Append -Encoding UTF8

# ── Rotate old logs ──────────────────────────────────────────
Get-ChildItem $logDir -Filter 'jobs-*.log' | Where-Object {
    $_.LastWriteTime -lt (Get-Date).AddDays(-$maxAgeDays)
} | Remove-Item -Force -ErrorAction SilentlyContinue
