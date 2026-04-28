<#
.SYNOPSIS
    Install the observability stack on a runner: windows_exporter,
    blackbox_exporter, and configure Docker + GitLab Runner to expose metrics.

.DESCRIPTION
    Three Prometheus targets are exposed by every runner:

      :9182  windows_exporter      (Windows host metrics: CPU, mem, disk, net, services)
      :9115  blackbox_exporter     (probes -- ICMP/TCP/HTTP from this runner)
      :9252  gitlab-runner metrics (job count, errors, build duration, runner version)
      :9323  Docker daemon metrics (engine state, containers, images)

    The first two are installed here:
      windows_exporter -- MSI install, registers a Windows service automatically
      blackbox_exporter -- portable .exe; we register it as a Windows service
                           via NSSM (which is already installed by Install-Tools)

    The runner and Docker endpoints are configured by Phase 2 (daemon.json
    metrics-addr) and Phase 3 (config.toml listen_address) -- this script
    only opens their inbound firewall ports.

.PARAMETER WindowsExporterMsi
    Local path to the staged windows_exporter MSI.
    Default: C:\Tools\windows_exporter\windows_exporter.msi

.PARAMETER BlackboxExporterZip
    Local path to the staged blackbox_exporter zip.
    Default: C:\Tools\blackbox_exporter\blackbox_exporter.zip

.PARAMETER BlackboxInstallDir
    Where blackbox_exporter is extracted to.
    Default: C:\Program Files\blackbox_exporter

.NOTES
    File:        scripts/Install-Observability.ps1
    Run as:      Administrator
    Called from: Phase 3 (after Install-Tools so NSSM is available)
    Depends on:  C:\Tools\nssm.exe (provided by Install-Tools)
    Idempotent:  Yes
#>

param(
    [string]$WindowsExporterMsi  = 'C:\Tools\windows_exporter\windows_exporter.msi',
    [string]$BlackboxExporterZip = 'C:\Tools\blackbox_exporter\blackbox_exporter.zip',
    # MUST be a path WITHOUT spaces -- NSSM stores AppParameters as a raw
    # whitespace-split string at service runtime, so a path containing spaces
    # would tokenise as multiple args and blackbox_exporter would fail to
    # parse --config.file=<path with space>\blackbox.yml.
    [string]$BlackboxInstallDir  = 'C:\Tools\blackbox_exporter',
    [int]$WindowsExporterPort    = 9182,
    [int]$BlackboxExporterPort   = 9115,
    [int]$RunnerMetricsPort      = 9252,
    [int]$DockerMetricsPort      = 9323
)

$ErrorActionPreference = 'Continue'

function Write-Step {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Output "[$ts] [$Level] $Message"
}

function Ensure-FirewallRule {
    param([string]$Name, [string]$DisplayName, [int]$Port)
    if (Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue) {
        Write-Step "  Firewall '$Name' (TCP $Port) already exists"
        return
    }
    New-NetFirewallRule `
        -Name        $Name `
        -DisplayName $DisplayName `
        -Direction   Inbound `
        -Protocol    TCP `
        -LocalPort   $Port `
        -Action      Allow `
        -Enabled     True | Out-Null
    Write-Step "  Firewall '$Name' created (TCP $Port inbound)"
}

# ============================================================
# 1. windows_exporter (MSI -- self-installs as a Windows service)
# ============================================================
Write-Step '========== Install-Observability =========='
Write-Step "1/4  windows_exporter (Prometheus host metrics on :$WindowsExporterPort)"

$wxSvc = Get-Service windows_exporter -ErrorAction SilentlyContinue
if ($wxSvc) {
    Write-Step "  windows_exporter service already present (status: $($wxSvc.Status))"
} else {
    if (-not (Test-Path $WindowsExporterMsi)) {
        Write-Step "  ERROR: $WindowsExporterMsi not staged" 'ERROR'
    } else {
        # Documented MSI properties (windows_exporter v0.30+):
        #   ENABLED_COLLECTORS, LISTEN_ADDR, LISTEN_PORT
        $msiArgs = @(
            '/i', "`"$WindowsExporterMsi`"",
            '/quiet', '/norestart',
            'ENABLED_COLLECTORS=cpu,cs,logical_disk,memory,net,os,service,system,tcp,terminal_services,container,iis',
            'LISTEN_ADDR=0.0.0.0',
            "LISTEN_PORT=$WindowsExporterPort"
        )
        Write-Step "  Running: msiexec $($msiArgs -join ' ')"
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs `
                              -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -notin 0,3010) {
            Write-Step "  ERROR: msiexec exit code $($proc.ExitCode)" 'ERROR'
        } else {
            Write-Step '  windows_exporter installed'
        }
    }
}
Set-Service windows_exporter -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service windows_exporter -ErrorAction SilentlyContinue
Ensure-FirewallRule -Name 'WindowsExporter-In-TCP' -DisplayName 'Prometheus windows_exporter' -Port $WindowsExporterPort

# ============================================================
# 2. blackbox_exporter (zip + NSSM-managed service)
# ============================================================
Write-Step ''
Write-Step "2/4  blackbox_exporter (probes on :$BlackboxExporterPort)"

$bbBin    = Join-Path $BlackboxInstallDir 'blackbox_exporter.exe'
$bbConfig = Join-Path $BlackboxInstallDir 'blackbox.yml'

# Extract binary if not already in place
if (-not (Test-Path $bbBin)) {
    if (-not (Test-Path $BlackboxExporterZip)) {
        Write-Step "  ERROR: $BlackboxExporterZip not staged" 'ERROR'
    } else {
        if (-not (Test-Path $BlackboxInstallDir)) {
            New-Item -Path $BlackboxInstallDir -ItemType Directory -Force | Out-Null
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $tmp = Join-Path $env:TEMP "blackbox-extract-$([Guid]::NewGuid().ToString('N'))"
        New-Item -Path $tmp -ItemType Directory -Force | Out-Null
        try {
            [System.IO.Compression.ZipFile]::ExtractToDirectory($BlackboxExporterZip, $tmp)
            $top = Get-ChildItem -Path $tmp -Force
            $source = if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $top[0].FullName } else { $tmp }
            Get-ChildItem -Path $source -Force |
                Copy-Item -Destination $BlackboxInstallDir -Recurse -Force
            Write-Step "  Extracted to $BlackboxInstallDir"
        } finally {
            Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Default blackbox.yml if not present (zip ships a sample, but ensure one exists)
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

# Register service via NSSM (installed by Install-Tools).
#
# NSSM caveats we work around here:
#   1. `nssm install <svc> <bin>` installs the service, then we set
#      AppParameters via a SEPARATE call. Inlining args after the binary
#      works for short args, but stores the args as a raw concatenated
#      string -- safer to set AppParameters explicitly.
#   2. `nssm install` returns non-zero on EVERY error (already-exists,
#      permission denied, etc.). Earlier code piped output but never
#      checked $LASTEXITCODE, so a real failure would be silently
#      logged and the script would continue.
#   3. AppDirectory must be set explicitly when the binary path contains
#      spaces -- but $BlackboxInstallDir is constrained to no-space paths
#      by Config.ps1, so we set it for hygiene.
$nssm = 'C:\Tools\nssm.exe'
$bbSvc = Get-Service blackbox_exporter -ErrorAction SilentlyContinue
if ($bbSvc) {
    Write-Step "  blackbox_exporter service already registered (status: $($bbSvc.Status))"
} elseif (-not (Test-Path $nssm)) {
    Write-Step "  ERROR: nssm.exe not found at $nssm -- cannot register service" 'ERROR'
} else {
    & $nssm install blackbox_exporter $bbBin 2>&1 |
        ForEach-Object { Write-Step "  nssm install: $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Step "  ERROR: nssm install exited $LASTEXITCODE -- aborting service config" 'ERROR'
    } else {
        $appParams = "--config.file=$bbConfig --web.listen-address=:$BlackboxExporterPort"
        & $nssm set blackbox_exporter AppParameters $appParams                     2>&1 | Out-Null
        & $nssm set blackbox_exporter AppDirectory  $BlackboxInstallDir            2>&1 | Out-Null
        & $nssm set blackbox_exporter Start         SERVICE_AUTO_START             2>&1 | Out-Null
        & $nssm set blackbox_exporter AppStdout     "$BlackboxInstallDir\blackbox_exporter.log"     2>&1 | Out-Null
        & $nssm set blackbox_exporter AppStderr     "$BlackboxInstallDir\blackbox_exporter.err.log" 2>&1 | Out-Null
        Write-Step '  blackbox_exporter registered as Windows service'
        Write-Step "  AppParameters: $appParams"
    }
}
Start-Service blackbox_exporter -ErrorAction SilentlyContinue
Ensure-FirewallRule -Name 'BlackboxExporter-In-TCP' -DisplayName 'Prometheus blackbox_exporter' -Port $BlackboxExporterPort

# ============================================================
# 3. GitLab Runner metrics endpoint (firewall only -- listen_address
#    is set in config.toml by Phase 3)
# ============================================================
Write-Step ''
Write-Step "3/4  GitLab Runner metrics firewall (TCP $RunnerMetricsPort)"
Ensure-FirewallRule -Name 'GitLabRunnerMetrics-In-TCP' -DisplayName 'GitLab Runner metrics' -Port $RunnerMetricsPort

# ============================================================
# 4. Docker daemon metrics endpoint (firewall only -- metrics-addr
#    is set in daemon.json by Phase 2)
# ============================================================
Write-Step ''
Write-Step "4/4  Docker daemon metrics firewall (TCP $DockerMetricsPort)"
Ensure-FirewallRule -Name 'DockerMetrics-In-TCP' -DisplayName 'Docker daemon metrics' -Port $DockerMetricsPort

Write-Step ''
Write-Step '========== Install-Observability COMPLETE =========='
Write-Output ''
Write-Output 'Prometheus scrape targets exposed by this runner:'
Write-Output "  http://$env:COMPUTERNAME`:$WindowsExporterPort/metrics      (windows_exporter)"
Write-Output "  http://$env:COMPUTERNAME`:$BlackboxExporterPort/probe        (blackbox_exporter)"
Write-Output "  http://$env:COMPUTERNAME`:$RunnerMetricsPort/metrics         (gitlab-runner)"
Write-Output "  http://$env:COMPUTERNAME`:$DockerMetricsPort/metrics         (Docker daemon)"
Write-Output ''
exit 0
