<#
.SYNOPSIS
    Install observability stack: windows_exporter + blackbox_exporter, and open
    firewall holes for runner (:9252) and Docker (:9323) metrics.
    HARDENED build -- proof against the "service not running" validation
    failures (Cluster 3). See PATCH-NOTES.md.

.DESCRIPTION
    What changed vs 2.4.6/2.4.7:
      * Self-staging fallback. If the exporter MSI/ZIP is not on disk (because
        the Phase 3 staging step discarded the Get-S3Object result with
        '| Out-Null' and silently failed), this script now locates Config.ps1 +
        Common.ps1 and downloads the binaries itself from the configured S3
        keys before giving up.
      * Magic-byte validation before install (rejects 0-byte / MinIO XML error
        bodies saved as a file).
      * Services are started with a retry+verify loop and a clear PASS/FAIL
        line, instead of a fire-and-forget Start-Service that hid failures.
      * blackbox_exporter still depends on C:\Tools\nssm.exe (from
        Install-Tools). If nssm is missing the script says so explicitly --
        fix Install-Tools (Cluster 1) first, then re-run.

.PARAMETER WindowsExporterMsi    Local path to the staged windows_exporter MSI.
.PARAMETER BlackboxExporterZip   Local path to the staged blackbox_exporter zip.
.PARAMETER BlackboxInstallDir    Where blackbox_exporter is extracted (NO spaces).
.PARAMETER WindowsExporterS3Key  MinIO key, used only for the self-staging fallback.
.PARAMETER BlackboxExporterS3Key MinIO key, used only for the self-staging fallback.

.NOTES
    File:        scripts/Install-Observability.ps1
    Run as:      Administrator
    Called from: Phase 3 (after Install-Tools so NSSM is available)
    Idempotent:  Yes
#>

param(
    [string]$WindowsExporterMsi   = 'C:\Tools\windows_exporter\windows_exporter.msi',
    [string]$BlackboxExporterZip  = 'C:\Tools\blackbox_exporter\blackbox_exporter.zip',
    [string]$BlackboxInstallDir   = 'C:\Tools\blackbox_exporter',
    [string]$WindowsExporterS3Key = 'tools/observability/windows_exporter-0.30.5-amd64.msi',
    [string]$BlackboxExporterS3Key= 'tools/observability/blackbox_exporter-0.27.0.windows-amd64.zip',
    [int]$WindowsExporterPort     = 9182,
    [int]$BlackboxExporterPort    = 9115,
    [int]$RunnerMetricsPort       = 9252,
    [int]$DockerMetricsPort       = 9323,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Continue'
$script:Failures = 0

function Write-Step {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Output "[$ts] [$Level] $Message"
}

# ============================================================
# CONFIG / S3 BOOTSTRAP -- enables the self-staging fallback
# ============================================================
if (-not $Script:Config) {
    if (-not $ConfigPath) {
        $candidates = @(
            (Join-Path $PSScriptRoot '..\bootstrap\lib\Config.ps1'),
            'C:\GitLab-Runner\lib\Config.ps1'
        )
        $ConfigPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if ($ConfigPath -and (Test-Path $ConfigPath)) { . $ConfigPath }
}
if (-not (Get-Command Copy-RepoFile -ErrorAction SilentlyContinue)) {
    if ($ConfigPath) {
        $commonPath = Join-Path (Split-Path $ConfigPath) 'Common.ps1'
        if (Test-Path $commonPath) { . $commonPath }
    }
}
# Prefer keys from Config if present (survives version bumps of the binaries).
if ($Script:Config -and $Script:Config.ObservabilityPackages) {
    if ($Script:Config.ObservabilityPackages.WindowsExporter.S3Key)  { $WindowsExporterS3Key  = $Script:Config.ObservabilityPackages.WindowsExporter.S3Key }
    if ($Script:Config.ObservabilityPackages.BlackboxExporter.S3Key) { $BlackboxExporterS3Key = $Script:Config.ObservabilityPackages.BlackboxExporter.S3Key }
}

# ============================================================
# HELPERS  (script scope -- PS 5.1 nested-function scope leak)
# ============================================================

function Test-MagicBytes {
    param([string]$Path, [string]$Kind)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try { if ((Get-Item -LiteralPath $Path).Length -lt 1) { return $false } } catch { return $false }
    $buf = New-Object byte[] 8; $n = 0; $fs = $null
    try { $fs = [System.IO.File]::OpenRead($Path); $n = $fs.Read($buf,0,8) }
    catch { return $false } finally { if ($fs) { $fs.Dispose() } }
    if ($n -lt 2) { return $false }
    if ($buf[0] -eq 0x3C) { return $false }   # '<' = HTML/XML error body
    switch ($Kind) {
        'msi' { return ($n -ge 4 -and $buf[0] -eq 0xD0 -and $buf[1] -eq 0xCF -and $buf[2] -eq 0x11 -and $buf[3] -eq 0xE0) }
        'zip' { return ($buf[0] -eq 0x50 -and $buf[1] -eq 0x4B) }
        default { return $true }
    }
}

function Stage-IfMissing {
    # $S3Key is a repo-relative path (the param name is kept for compatibility).
    # Phase3-Install normally stages these first; this is the self-staging fallback.
    param([string]$LocalPath, [string]$S3Key, [string]$Kind, [string]$Label)
    if (Test-MagicBytes -Path $LocalPath -Kind $Kind) { return $true }
    if (Test-Path $LocalPath) { Remove-Item $LocalPath -Force -ErrorAction SilentlyContinue }
    if (-not (Get-Command Copy-RepoFile -ErrorAction SilentlyContinue)) {
        Write-Step "  ERROR: $Label not staged and Copy-RepoFile unavailable -- cannot self-stage" 'ERROR'
        return $false
    }
    $dir = Split-Path $LocalPath -Parent
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    Write-Step "  $Label not staged -- self-staging from repo:$S3Key"
    if (-not (Copy-RepoFile -RelPath $S3Key -OutFile $LocalPath)) {
        Write-Step "  ERROR: copy failed for $Label ($S3Key) -- path likely missing in the uploaded repo" 'ERROR'
        return $false
    }
    if (-not (Test-MagicBytes -Path $LocalPath -Kind $Kind)) {
        Write-Step "  ERROR: $Label staged but failed $Kind validation" 'ERROR'
        return $false
    }
    return $true
}

function Start-ServiceWithRetry {
    param([string]$Name, [int]$TimeoutSeconds = 30, [int]$PollSeconds = 3)
    # Fast-fail if the service was never registered (e.g. MSI staging failed) --
    # otherwise the loop below would burn the full timeout polling a ghost.
    if (-not (Get-Service -Name $Name -ErrorAction SilentlyContinue)) { return $false }
    Set-Service $Name -StartupType Automatic -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { return $true }
        if ($svc) { Start-Service -Name $Name -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds $PollSeconds
    }
    return $false
}

function Ensure-FirewallRule {
    param([string]$Name, [string]$DisplayName, [int]$Port)
    if (Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue) {
        Write-Step "  Firewall '$Name' (TCP $Port) already exists"
        return
    }
    try {
        New-NetFirewallRule -Name $Name -DisplayName $DisplayName -Direction Inbound `
            -Protocol TCP -LocalPort $Port -Action Allow -Enabled True -ErrorAction Stop | Out-Null
    } catch {
        Write-Step "  [FAIL] firewall '$Name' (TCP $Port): $($_.Exception.Message)" 'ERROR'; $script:Failures++; return
    }
    if (Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue) {
        Write-Step "  Firewall '$Name' created (TCP $Port inbound)"
    } else {
        Write-Step "  [FAIL] firewall '$Name' missing after create" 'ERROR'; $script:Failures++
    }
}

# ============================================================
# 1. windows_exporter (MSI -- self-installs as a Windows service)
# ============================================================
Write-Step '========== Install-Observability (hardened) =========='
Write-Step "1/4  windows_exporter (Prometheus host metrics on :$WindowsExporterPort)"

$wxSvc = Get-Service windows_exporter -ErrorAction SilentlyContinue
if ($wxSvc) {
    Write-Step "  windows_exporter service already present (status: $($wxSvc.Status))"
} elseif (Stage-IfMissing -LocalPath $WindowsExporterMsi -S3Key $WindowsExporterS3Key -Kind 'msi' -Label 'windows_exporter MSI') {
    $msiArgs = @(
        '/i', "`"$WindowsExporterMsi`"",
        '/quiet', '/norestart',
        'ENABLED_COLLECTORS=cpu,cs,logical_disk,memory,net,os,service,system,tcp,terminal_services,container,iis',
        'LISTEN_ADDR=0.0.0.0',
        "LISTEN_PORT=$WindowsExporterPort"
    )
    Write-Step "  Running: msiexec $($msiArgs -join ' ')"
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -notin 0,3010) {
        Write-Step "  ERROR: msiexec exit code $($proc.ExitCode)" 'ERROR'
    } else {
        Write-Step '  windows_exporter MSI installed'
    }
}
if (Start-ServiceWithRetry -Name 'windows_exporter') {
    Write-Step '  [PASS] windows_exporter service is RUNNING'
} else {
    Write-Step '  [FAIL] windows_exporter service not running (check MSI staging + msiexec log)' 'ERROR'; $script:Failures++
}
Ensure-FirewallRule -Name 'WindowsExporter-In-TCP' -DisplayName 'Prometheus windows_exporter' -Port $WindowsExporterPort

# ============================================================
# 2. blackbox_exporter (zip + NSSM-managed service)
# ============================================================
Write-Step ''
Write-Step "2/4  blackbox_exporter (probes on :$BlackboxExporterPort)"

$bbBin    = Join-Path $BlackboxInstallDir 'blackbox_exporter.exe'
$bbConfig = Join-Path $BlackboxInstallDir 'blackbox.yml'

if (-not (Test-Path $bbBin)) {
    if (Stage-IfMissing -LocalPath $BlackboxExporterZip -S3Key $BlackboxExporterS3Key -Kind 'zip' -Label 'blackbox_exporter ZIP') {
        if (-not (Test-Path $BlackboxInstallDir)) { New-Item -Path $BlackboxInstallDir -ItemType Directory -Force | Out-Null }
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $tmp = Join-Path $env:TEMP "blackbox-extract-$([Guid]::NewGuid().ToString('N'))"
        New-Item -Path $tmp -ItemType Directory -Force | Out-Null
        try {
            [System.IO.Compression.ZipFile]::ExtractToDirectory($BlackboxExporterZip, $tmp)
            $top = @(Get-ChildItem -Path $tmp -Force)
            $source = if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $top[0].FullName } else { $tmp }
            Get-ChildItem -Path $source -Force | Copy-Item -Destination $BlackboxInstallDir -Recurse -Force
            Write-Step "  Extracted to $BlackboxInstallDir"
        } finally {
            Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not (Test-Path $bbConfig)) {
    @'
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      preferred_ip_protocol: ip4
      tls_config:
        insecure_skip_verify: true
  tcp_connect:
    prober: tcp
    timeout: 5s
  icmp:
    prober: icmp
    timeout: 5s
'@ | Out-File -FilePath $bbConfig -Encoding UTF8 -Force
    Write-Step "  Wrote default $bbConfig"
}

$nssm  = 'C:\Tools\nssm.exe'
$bbSvc = Get-Service blackbox_exporter -ErrorAction SilentlyContinue
if ($bbSvc) {
    Write-Step "  blackbox_exporter service already registered (status: $($bbSvc.Status))"
} elseif (-not (Test-Path $bbBin)) {
    Write-Step "  ERROR: $bbBin missing -- cannot register service (staging/extract failed)" 'ERROR'
} elseif (-not (Test-Path $nssm)) {
    Write-Step "  ERROR: nssm.exe not found at $nssm -- fix Install-Tools (Cluster 1) then re-run" 'ERROR'
} else {
    & $nssm install blackbox_exporter $bbBin 2>&1 | ForEach-Object { Write-Step "  nssm install: $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Step "  ERROR: nssm install exited $LASTEXITCODE -- aborting service config" 'ERROR'
    } else {
        $appParams = "--config.file=$bbConfig --web.listen-address=:$BlackboxExporterPort"
        & $nssm set blackbox_exporter AppParameters $appParams                       2>&1 | Out-Null
        & $nssm set blackbox_exporter AppDirectory  $BlackboxInstallDir              2>&1 | Out-Null
        & $nssm set blackbox_exporter Start         SERVICE_AUTO_START               2>&1 | Out-Null
        & $nssm set blackbox_exporter AppStdout     "$BlackboxInstallDir\blackbox_exporter.log"     2>&1 | Out-Null
        & $nssm set blackbox_exporter AppStderr     "$BlackboxInstallDir\blackbox_exporter.err.log" 2>&1 | Out-Null
        Write-Step '  blackbox_exporter registered as Windows service'
    }
}
if (Get-Service blackbox_exporter -ErrorAction SilentlyContinue) {
    if (Start-ServiceWithRetry -Name 'blackbox_exporter') {
        Write-Step '  [PASS] blackbox_exporter service is RUNNING'
    } else {
        Write-Step '  [FAIL] blackbox_exporter registered but not running (check blackbox_exporter.err.log)' 'ERROR'; $script:Failures++
    }
} else {
    Write-Step '  [FAIL] blackbox_exporter service not registered' 'ERROR'; $script:Failures++
}
Ensure-FirewallRule -Name 'BlackboxExporter-In-TCP' -DisplayName 'Prometheus blackbox_exporter' -Port $BlackboxExporterPort

# ============================================================
# 3-4. Metrics firewall holes (runner :9252 set in config.toml,
#      Docker :9323 set in daemon.json -- here we only open the ports)
# ============================================================
Write-Step ''
Write-Step "3/4  GitLab Runner metrics firewall (TCP $RunnerMetricsPort)"
Ensure-FirewallRule -Name 'GitLabRunnerMetrics-In-TCP' -DisplayName 'GitLab Runner metrics' -Port $RunnerMetricsPort

Write-Step ''
Write-Step "4/4  Docker daemon metrics firewall (TCP $DockerMetricsPort)"
Ensure-FirewallRule -Name 'DockerMetrics-In-TCP' -DisplayName 'Docker daemon metrics' -Port $DockerMetricsPort

Write-Step ''
Write-Step '========== Install-Observability COMPLETE =========='
if ($script:Failures -gt 0) {
    Write-Step "  $script:Failures component(s) failed -- exiting 1" 'ERROR'
    exit 1
}
exit 0
