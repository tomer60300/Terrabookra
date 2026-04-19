<#
.SYNOPSIS
    Network connectivity monitor -- tests TCP connectivity to defined hosts.

.DESCRIPTION
    Runs every 2 minutes via scheduled task (Network-Connectivity-Monitor).
    Tests TCP connection to each host:port pair and logs results to a daily CSV.

    Host list is loaded from (in priority order):
      1. -Hosts parameter (if passed)
      2. C:\GitLab-Runner\scripts\monitor-hosts.json (deployed by Phase 3 from Config)
      3. Empty -- script exits with warning

    When a pipeline fails with a timeout, grep the CSV for that time window:
      Import-Csv C:\GitLab-Runner\logs\network\net-2026-04-16.csv |
        Where-Object { $_.Timestamp -gt '2026-04-16T14:00' -and $_.Success -eq 'False' }

    History auto-rotated: files older than MaxAgeDays are deleted.

.PARAMETER Hosts
    Array of hashtables with Host and Port keys. Overrides JSON config.

.PARAMETER LogDir
    Directory for CSV logs. Default: C:\GitLab-Runner\logs\network

.PARAMETER MaxAgeDays
    Days to keep old CSV logs. Default: 30

.NOTES
    File: scripts/Test-NetworkConnectivity.ps1
    Log: <LogDir>\net-YYYY-MM-DD.csv

    CSV columns: Timestamp, Host, Port, Success, LatencyMs, Error
#>

param(
    [hashtable[]]$Hosts,
    [string]$LogDir     = 'C:\GitLab-Runner\logs\network',
    [int]$MaxAgeDays    = 30
)

$ErrorActionPreference = 'Continue'

if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

# -- Load hosts from JSON config if not passed ----------------
if (-not $Hosts -or $Hosts.Count -eq 0) {
    $configJson = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\monitor-hosts.json'
    if (-not (Test-Path $configJson)) {
        $configJson = Join-Path $PSScriptRoot 'monitor-hosts.json'
    }
    if (Test-Path $configJson) {
        try {
            $jsonHosts = @(Get-Content $configJson -Raw | ConvertFrom-Json)
            $Hosts = @()
            foreach ($h in $jsonHosts) {
                $Hosts += @{ Host = $h.Host; Port = [int]$h.Port }
            }
        }
        catch {
            Write-Warning "Failed to parse monitor-hosts.json: $_"
        }
    }
}

if (-not $Hosts -or $Hosts.Count -eq 0) {
    Write-Warning 'No monitor hosts configured. Pass -Hosts or deploy monitor-hosts.json.'
    return
}

# -- Daily CSV file -------------------------------------------
$today   = Get-Date -Format 'yyyy-MM-dd'
$csvFile = Join-Path $LogDir "net-$today.csv"

# Create header if new file
if (-not (Test-Path $csvFile)) {
    'Timestamp,Host,Port,Success,LatencyMs,Error' | Out-File $csvFile -Encoding UTF8
}

# -- Test each host -------------------------------------------
$now = Get-Date -Format 'o'

foreach ($h in $Hosts) {
    $host_  = $h.Host
    $port   = $h.Port
    $error_ = ''
    $latency = 0
    $success = $false

    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Test-NetConnection -ComputerName $host_ -Port $port -WarningAction SilentlyContinue
        $sw.Stop()
        $latency = $sw.ElapsedMilliseconds
        $success = $result.TcpTestSucceeded
        if (-not $success) { $error_ = 'TCP connection failed' }
    }
    catch {
        $error_ = $_.Exception.Message -replace ',', ';'
    }

    # Escape CSV fields
    "$now,$host_,$port,$success,$latency,$error_" | Out-File $csvFile -Append -Encoding UTF8
}

# -- Rotate old logs ------------------------------------------
Get-ChildItem $LogDir -Filter 'net-*.csv' | Where-Object {
    $_.LastWriteTime -lt (Get-Date).AddDays(-$MaxAgeDays)
} | Remove-Item -Force -ErrorAction SilentlyContinue
