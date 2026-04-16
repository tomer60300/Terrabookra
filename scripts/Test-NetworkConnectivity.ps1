<#
.SYNOPSIS
    Network connectivity monitor — tests TCP connectivity to defined hosts.

.DESCRIPTION
    Runs every 2 minutes via scheduled task (Network-Connectivity-Monitor).
    Tests TCP connection to each host:port pair and logs results to a daily CSV.

    When a pipeline fails with a timeout, grep the CSV for that time window:
      Import-Csv C:\GitLab-Runner\logs\network\net-2026-04-16.csv |
        Where-Object { $_.Timestamp -gt '2026-04-16T14:00' -and $_.Success -eq 'False' }

    History auto-rotated: files older than 30 days are deleted.

.PARAMETER Hosts
    Array of hashtables with Host and Port keys. Overrides defaults from Config.

.NOTES
    File: scripts/Test-NetworkConnectivity.ps1
    Log: C:\GitLab-Runner\logs\network\net-YYYY-MM-DD.csv

    CSV columns: Timestamp, Host, Port, Success, LatencyMs, Error
#>

param(
    [hashtable[]]$Hosts
)

$ErrorActionPreference = 'Continue'
$logDir     = 'C:\GitLab-Runner\logs\network'
$maxAgeDays = 30

if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

# Default hosts if not passed
if (-not $Hosts -or $Hosts.Count -eq 0) {
    $Hosts = @(
        @{ Host = 'gitlab.kayhut.com';      Port = 443  },
        @{ Host = 'harbor.kayhut.com';      Port = 443  },
        @{ Host = 'kayhut-minio.com';       Port = 9000 },
        @{ Host = 'artifactory-prod';       Port = 443  },
        @{ Host = 'be1.kayhut.com';         Port = 443  }
    )
}

# ── Daily CSV file ───────────────────────────────────────────
$today   = Get-Date -Format 'yyyy-MM-dd'
$csvFile = Join-Path $logDir "net-$today.csv"

# Create header if new file
if (-not (Test-Path $csvFile)) {
    'Timestamp,Host,Port,Success,LatencyMs,Error' | Out-File $csvFile -Encoding UTF8
}

# ── Test each host ───────────────────────────────────────────
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

# ── Rotate old logs ──────────────────────────────────────────
Get-ChildItem $logDir -Filter 'net-*.csv' | Where-Object {
    $_.LastWriteTime -lt (Get-Date).AddDays(-$maxAgeDays)
} | Remove-Item -Force -ErrorAction SilentlyContinue
