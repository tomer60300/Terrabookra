<#
.SYNOPSIS
    Fleet health dashboard -- query all runners via OpenSSH, display status table.

.DESCRIPTION
    Run this from your ADMIN PC (not on the runners). Connects to each runner
    via OpenSSH, runs a PowerShell probe, parses the JSON output, and displays
    a table of healthy/degraded/unreachable hosts.

    Replaces the prior PSRemoting/WinRM transport (blocked at Kayhut by GPO).
    OpenSSH is enabled on every runner by Phase 1 step 1.11.

    Auth: same options as Invoke-FleetCommand.ps1 (SSH key recommended for
    fleet ops; AD password works but prompts per host; GSSAPI for passwordless
    on a domain-joined admin PC).

.PARAMETER Runners
    Array of runner hostnames or IPs.

.PARAMETER SshUser
    Username for SSH login. Defaults to current user.

.PARAMETER PrivateKey
    Path to an SSH private key (e.g. ~/.ssh/id_ed25519).

.PARAMETER KerberosAuth
    Use GSSAPI/Kerberos auth.

.PARAMETER RunnerDir
    Base runner directory on remote hosts. Default: C:\GitLab-Runner

.PARAMETER ExportCsv
    Optional path to export results as CSV.

.NOTES
    File: fleet/Get-FleetHealth.ps1
    Runs on: Admin PC (NOT on runners).
#>

param(
    [Parameter(Mandatory)]
    [string[]]$Runners,

    [string]$SshUser,
    [string]$PrivateKey,
    [switch]$KerberosAuth,

    [string]$RunnerDir = 'C:\GitLab-Runner',
    [string]$ExportCsv
)

$ErrorActionPreference = 'Continue'

# Probe template -- $RunnerDir gets baked in before encoding for transport.
$probeTemplate = @'
$RunnerDir   = '__RUNNER_DIR__'
$runnerBin   = Join-Path $RunnerDir 'gitlab-runner.exe'
$versionFile = Join-Path $RunnerDir '.golden-version'

$result = [ordered]@{
    Hostname           = $env:COMPUTERNAME
    Status             = 'HEALTHY'
    Uptime             = ''
    DiskFreeC_GB       = 0
    DiskFreeE_GB       = 'N/A'
    DockerStatus       = 'Unknown'
    DockerVersion      = 'Unknown'
    RunnerStatus       = 'Unknown'
    RunnerAlive        = $false
    Containers         = 0
    Images             = 0
    ImageVersion       = 'Unknown'
    ScheduledTasks     = 0
    SshdStatus         = 'Unknown'
    WinExporterStatus  = 'Unknown'
    BlackboxStatus     = 'Unknown'
}

try {
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $up   = (Get-Date) - $boot
    $result.Uptime = '{0}d {1:D2}:{2:D2}' -f $up.Days, $up.Hours, $up.Minutes
} catch {}

try {
    $result.DiskFreeC_GB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
    if (Test-Path 'E:\') { $result.DiskFreeE_GB = [math]::Round((Get-PSDrive E).Free / 1GB, 1) }
} catch {}

try {
    $svc = Get-Service docker -ErrorAction SilentlyContinue
    $result.DockerStatus = if ($svc) { $svc.Status.ToString() } else { 'NOT FOUND' }
    if ($svc -and $svc.Status -eq 'Running') {
        $result.DockerVersion = docker version --format '{{.Server.Version}}' 2>$null
        $result.Containers    = [int](docker ps -q 2>$null | Measure-Object).Count
        $result.Images        = [int](docker images -q 2>$null | Measure-Object).Count
    }
} catch {}

try {
    $svc = Get-Service gitlab-runner -ErrorAction SilentlyContinue
    $result.RunnerStatus = if ($svc) { $svc.Status.ToString() } else { 'NOT FOUND' }
    if ($svc -and $svc.Status -eq 'Running') {
        $verify = & $runnerBin verify 2>&1 | Out-String
        $result.RunnerAlive = $verify -match 'is alive'
    }
} catch {}

if (Test-Path $versionFile) {
    try {
        $ver = Get-Content $versionFile -Raw | ConvertFrom-Json
        $result.ImageVersion = $ver.ImageVersion
    } catch {}
}

try {
    $result.ScheduledTasks = (Get-ScheduledTask |
        Where-Object { $_.TaskName -match '^(Docker|Runner|Disk|Log|Network|RDP)-' } |
        Measure-Object).Count
} catch {}

foreach ($s in @('sshd','windows_exporter','blackbox_exporter')) {
    $svc = Get-Service $s -ErrorAction SilentlyContinue
    $val = if ($svc) { $svc.Status.ToString() } else { 'NOT FOUND' }
    switch ($s) {
        'sshd'              { $result.SshdStatus        = $val }
        'windows_exporter'  { $result.WinExporterStatus = $val }
        'blackbox_exporter' { $result.BlackboxStatus    = $val }
    }
}

$degraded = @()
if ($result.DockerStatus       -ne 'Running') { $degraded += 'Docker' }
if ($result.RunnerStatus       -ne 'Running') { $degraded += 'Runner' }
if (-not $result.RunnerAlive)                  { $degraded += 'RunnerNotAlive' }
if ($result.SshdStatus         -ne 'Running') { $degraded += 'sshd' }
if ($result.WinExporterStatus  -ne 'Running') { $degraded += 'WindowsExporter' }
if ($result.BlackboxStatus     -ne 'Running') { $degraded += 'BlackboxExporter' }
if ($result.DiskFreeC_GB -lt 20) { $degraded += 'DiskC' }
if ($result.DiskFreeE_GB -ne 'N/A' -and $result.DiskFreeE_GB -lt 20) { $degraded += 'DiskE' }

if ($degraded.Count -gt 0) {
    $result.Status = "DEGRADED ($($degraded -join ', '))"
}

[pscustomobject]$result | ConvertTo-Json -Compress
'@

$probe = $probeTemplate -replace '__RUNNER_DIR__', ($RunnerDir -replace "'","''")
$bytes = [System.Text.Encoding]::Unicode.GetBytes($probe)
$b64   = [Convert]::ToBase64String($bytes)

$baseArgs = @(
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', 'UserKnownHostsFile=~/.ssh/fleet_known_hosts',
    '-o', 'BatchMode=no',
    '-o', 'ConnectTimeout=10'
)
if ($PrivateKey)   { $baseArgs += @('-i', $PrivateKey) }
if ($KerberosAuth) { $baseArgs += @('-o', 'GSSAPIAuthentication=yes', '-o', 'GSSAPIDelegateCredentials=yes') }

Write-Output "`n  Querying $($Runners.Count) runner(s)...`n"

$results = @()
foreach ($runner in $Runners) {
    $target  = if ($SshUser) { "$SshUser@$runner" } else { $runner }
    $sshArgs = $baseArgs + @($target, 'powershell.exe', '-NoProfile', '-EncodedCommand', $b64)
    $stdout  = & ssh @sshArgs 2>$null
    if ($LASTEXITCODE -eq 0 -and $stdout) {
        try {
            $r = $stdout -join "`n" | ConvertFrom-Json
            $results += $r
        } catch {
            $results += [PSCustomObject][ordered]@{
                Hostname = $runner; Status = 'PARSE_ERROR'; Uptime = '-'
                DiskFreeC_GB = '-'; DiskFreeE_GB = '-'
                DockerStatus = '-'; DockerVersion = '-'
                RunnerStatus = '-'; RunnerAlive = '-'
                Containers = '-'; Images = '-'
                ImageVersion = '-'; ScheduledTasks = '-'
                SshdStatus = '-'; WinExporterStatus = '-'; BlackboxStatus = '-'
            }
        }
    } else {
        $results += [PSCustomObject][ordered]@{
            Hostname = $runner; Status = 'UNREACHABLE'; Uptime = '-'
            DiskFreeC_GB = '-'; DiskFreeE_GB = '-'
            DockerStatus = '-'; DockerVersion = '-'
            RunnerStatus = '-'; RunnerAlive = '-'
            Containers = '-'; Images = '-'
            ImageVersion = '-'; ScheduledTasks = '-'
            SshdStatus = '-'; WinExporterStatus = '-'; BlackboxStatus = '-'
        }
    }
}

$results | Format-Table -AutoSize -Property @(
    'Hostname','Status','ImageVersion','Uptime',
    'DiskFreeC_GB','DiskFreeE_GB','DockerStatus','RunnerStatus',
    'RunnerAlive','Containers','SshdStatus','WinExporterStatus','BlackboxStatus'
)

$healthy     = ($results | Where-Object { $_.Status -eq 'HEALTHY' }).Count
$degraded    = ($results | Where-Object { $_.Status -like 'DEGRADED*' }).Count
$unreachable = ($results | Where-Object { $_.Status -eq 'UNREACHABLE' }).Count
Write-Output "Fleet: $healthy healthy, $degraded degraded, $unreachable unreachable (total: $($Runners.Count))"

if ($ExportCsv) {
    $results | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Output "Exported to: $ExportCsv"
}
