<#
.SYNOPSIS
    Fleet health dashboard — query all runners via PSRemoting, display status table.

.DESCRIPTION
    Run this from your ADMIN PC (not on the runners).
    Connects to each runner via WinRM, collects health data, and displays
    a color-coded table showing which runners are healthy/degraded.

    Prerequisites:
      - WinRM enabled on all runners (Enable-RemotePowerShell.ps1)
      - Your admin PC can reach runners on TCP 5985
      - Credentials with admin access on the runners

    Usage:
      .\Get-FleetHealth.ps1 -Runners runner01,runner02,runner03
      .\Get-FleetHealth.ps1 -Runners (Get-Content .\runners.txt)
      .\Get-FleetHealth.ps1 -Runners runner01,runner02 -Credential (Get-Credential)

.PARAMETER Runners
    Array of runner hostnames or IPs.

.PARAMETER Credential
    PSCredential for authentication. If omitted, uses current user (domain auth).

.PARAMETER ExportCsv
    Optional path to export results as CSV.

.NOTES
    File: fleet/Get-FleetHealth.ps1
    Runs on: Admin PC (NOT on runners)
#>

param(
    [Parameter(Mandatory)]
    [string[]]$Runners,

    [PSCredential]$Credential,

    [string]$ExportCsv
)

$ErrorActionPreference = 'Continue'

# ── Remote script block ──────────────────────────────────────
$probe = {
    $result = [ordered]@{
        Hostname      = $env:COMPUTERNAME
        Status        = 'HEALTHY'
        Uptime        = ''
        DiskFreeC_GB  = 0
        DiskFreeE_GB  = 'N/A'
        DockerStatus  = 'Unknown'
        DockerVersion = 'Unknown'
        RunnerStatus  = 'Unknown'
        RunnerAlive   = $false
        Containers    = 0
        Images        = 0
        ImageVersion  = 'Unknown'
        ScheduledTasks = 0
    }

    # Uptime
    try {
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        $up   = (Get-Date) - $boot
        $result.Uptime = '{0}d {1:D2}:{2:D2}' -f $up.Days, $up.Hours, $up.Minutes
    } catch {}

    # Disk
    try {
        $result.DiskFreeC_GB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
        if (Test-Path 'E:\') {
            $result.DiskFreeE_GB = [math]::Round((Get-PSDrive E).Free / 1GB, 1)
        }
    } catch {}

    # Docker
    try {
        $svc = Get-Service docker -ErrorAction SilentlyContinue
        $result.DockerStatus = if ($svc) { $svc.Status.ToString() } else { 'NOT FOUND' }
        if ($svc -and $svc.Status -eq 'Running') {
            $result.DockerVersion = docker version --format '{{.Server.Version}}' 2>$null
            $result.Containers    = [int](docker ps -q 2>$null | Measure-Object).Count
            $result.Images        = [int](docker images -q 2>$null | Measure-Object).Count
        }
    } catch {}

    # Runner
    try {
        $svc = Get-Service gitlab-runner -ErrorAction SilentlyContinue
        $result.RunnerStatus = if ($svc) { $svc.Status.ToString() } else { 'NOT FOUND' }
        if ($svc -and $svc.Status -eq 'Running') {
            $verify = & 'C:\GitLab-Runner\gitlab-runner.exe' verify 2>&1 | Out-String
            $result.RunnerAlive = $verify -match 'is alive'
        }
    } catch {}

    # Golden version
    $vf = 'C:\GitLab-Runner\.golden-version'
    if (Test-Path $vf) {
        try {
            $ver = Get-Content $vf -Raw | ConvertFrom-Json
            $result.ImageVersion = $ver.ImageVersion
        } catch {}
    }

    # Scheduled tasks
    try {
        $result.ScheduledTasks = (Get-ScheduledTask |
            Where-Object { $_.TaskName -match '^(Docker|Runner|Disk|Log|Network|RDP)-' } |
            Measure-Object).Count
    } catch {}

    # Determine overall status
    $degraded = @()
    if ($result.DockerStatus -ne 'Running')  { $degraded += 'Docker' }
    if ($result.RunnerStatus -ne 'Running')  { $degraded += 'Runner' }
    if (-not $result.RunnerAlive)            { $degraded += 'RunnerNotAlive' }
    if ($result.DiskFreeC_GB -lt 20)         { $degraded += 'DiskLow' }

    if ($degraded.Count -gt 0) {
        $result.Status = "DEGRADED ($($degraded -join ', '))"
    }

    [PSCustomObject]$result
}

# ── Execute across fleet ─────────────────────────────────────
Write-Output "`n  Querying $($Runners.Count) runner(s)...`n"

$sessionParams = @{
    ComputerName = $Runners
    ErrorAction  = 'SilentlyContinue'
}
if ($Credential) { $sessionParams.Credential = $Credential }

$results = @()

# Collect results (with timeout handling for unreachable hosts)
foreach ($runner in $Runners) {
    $invokeParams = @{
        ComputerName = $runner
        ScriptBlock  = $probe
        ErrorAction  = 'SilentlyContinue'
        ErrorVariable = 'remoteErr'
    }
    if ($Credential) { $invokeParams.Credential = $Credential }

    $r = Invoke-Command @invokeParams

    if ($r) {
        $results += $r
    } else {
        $results += [PSCustomObject][ordered]@{
            Hostname       = $runner
            Status         = 'UNREACHABLE'
            Uptime         = '-'
            DiskFreeC_GB   = '-'
            DiskFreeE_GB   = '-'
            DockerStatus   = '-'
            DockerVersion  = '-'
            RunnerStatus   = '-'
            RunnerAlive    = '-'
            Containers     = '-'
            Images         = '-'
            ImageVersion   = '-'
            ScheduledTasks = '-'
        }
    }
}

# ── Display ──────────────────────────────────────────────────
$results | Format-Table -AutoSize -Property @(
    'Hostname', 'Status', 'ImageVersion', 'Uptime',
    'DiskFreeC_GB', 'DockerStatus', 'RunnerStatus',
    'RunnerAlive', 'Containers'
)

# Summary
$healthy     = ($results | Where-Object { $_.Status -eq 'HEALTHY' }).Count
$degraded    = ($results | Where-Object { $_.Status -like 'DEGRADED*' }).Count
$unreachable = ($results | Where-Object { $_.Status -eq 'UNREACHABLE' }).Count
Write-Output "Fleet: $healthy healthy, $degraded degraded, $unreachable unreachable (total: $($Runners.Count))"

# ── Optional CSV export ──────────────────────────────────────
if ($ExportCsv) {
    $results | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Output "Exported to: $ExportCsv"
}
