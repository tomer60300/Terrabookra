<#
.SYNOPSIS
    Job wrapper logger — logs CI job start/end to a daily file on the host.

.DESCRIPTION
    Called from config.toml as pre_build_script (action=start) and
    post_build_script (action=end).

    Writes a structured log line for each job event to a daily log file.
    History auto-rotated: files older than MaxAgeDays are deleted.

    Usage in config.toml:
      pre_build_script  = "powershell -NoProfile -File C:\\GitLab-Runner\\scripts\\Write-JobLog.ps1 -Action start"
      post_build_script = "powershell -NoProfile -File C:\\GitLab-Runner\\scripts\\Write-JobLog.ps1 -Action end"

.PARAMETER Action
    'start' or 'end'

.PARAMETER LogDir
    Directory for daily job log files. Default: C:\GitLab-Runner\logs\jobs

.PARAMETER MaxAgeDays
    Days to keep old log files. Default: 30

.NOTES
    File: scripts/Write-JobLog.ps1
    Log: <LogDir>\jobs-YYYY-MM-DD.log

    Environment variables used (set by GitLab Runner):
      CI_JOB_ID, CI_JOB_NAME, CI_PROJECT_NAME, CI_PIPELINE_ID,
      CI_PIPELINE_SOURCE, GITLAB_USER_LOGIN, CI_JOB_STATUS (post only)
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet('start', 'end')]
    [string]$Action,

    [string]$LogDir     = 'C:\GitLab-Runner\logs\jobs',
    [int]$MaxAgeDays    = 30
)

$ErrorActionPreference = 'Continue'

if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

# ── Gather job info from CI environment variables ────────────
$now         = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
$today       = Get-Date -Format 'yyyy-MM-dd'
$jobId       = if ($env:CI_JOB_ID)           { $env:CI_JOB_ID }           else { 'unknown' }
$jobName     = if ($env:CI_JOB_NAME)         { $env:CI_JOB_NAME }         else { 'unknown' }
$project     = if ($env:CI_PROJECT_NAME)     { $env:CI_PROJECT_NAME }     else { 'unknown' }
$pipelineId  = if ($env:CI_PIPELINE_ID)      { $env:CI_PIPELINE_ID }      else { 'unknown' }
$source      = if ($env:CI_PIPELINE_SOURCE)  { $env:CI_PIPELINE_SOURCE }  else { 'unknown' }
$user        = if ($env:GITLAB_USER_LOGIN)   { $env:GITLAB_USER_LOGIN }   else { 'unknown' }
$status      = if ($env:CI_JOB_STATUS)       { $env:CI_JOB_STATUS }       else { 'n/a' }
$hostname    = $env:COMPUTERNAME

$logFile = Join-Path $LogDir "jobs-$today.log"

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
Get-ChildItem $LogDir -Filter 'jobs-*.log' | Where-Object {
    $_.LastWriteTime -lt (Get-Date).AddDays(-$MaxAgeDays)
} | Remove-Item -Force -ErrorAction SilentlyContinue
