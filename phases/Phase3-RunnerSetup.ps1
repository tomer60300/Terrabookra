<#
.SYNOPSIS
    Phase 3 -- Docker verify, runner install, registration, maintenance, validation.

.DESCRIPTION
    Called after Phase 2 marker is detected. Final phase -- no reboot after this.

    3.1   Verify Docker daemon (12 attempts)
    3.2   Configure Windows Defender (exclusions + scheduled scan only)
    3.3   Install MinGit
    3.4   Download GitLab Runner binary
    3.5   Pre-pull Harbor container images (PARALLEL background jobs;
          waited for just before 3.15 so 3.6 -- 3.14 run concurrently)
    3.6   Resolve token (glrt- auth token vs registration token / PAT)
    3.7   Register runner (skipped if glrt- token) + write config.toml
          (config.toml includes listen_address = ":9252" for runner metrics)
    3.8   Install runner as Windows service (idempotent stop/uninstall)
    3.9   Deploy maintenance scripts from MinIO
    3.10  Deploy monitor-hosts.json for network connectivity script
    3.11  Register scheduled tasks
    3.12  Install tools (table-driven via scripts/Install-Tools.ps1):
          WinRAR, NSSM, Sysinternals, Notepad++, WinMerge, BareTail, Klogg,
          Everything, WizTree, System Informer, EventLook, Wireshark/tshark,
          Chrome, Windows Terminal (with PostInstall: set as default UX)
    3.13  Install OpenCode (WebView2 prerequisite + machine-wide config)
    3.14  Install observability stack:
          windows_exporter (MSI service), blackbox_exporter (NSSM service),
          firewall holes for runner :9252 and Docker :9323 metrics
    3.15  Final validation
    3.16  Write golden image version stamp

.NOTES
    File: phases/Phase3-RunnerSetup.ps1
    Requires: lib/Config.ps1, lib/Common.ps1, validation/Invoke-FinalValidation.ps1
#>

function Invoke-Phase3 {
    Write-Log '========== PHASE 3: Runner Setup & Configuration =========='
    $Script:ProvisioningFailed = $false

    # -- 3.1 Verify Docker daemon -----------------------------
    Write-Log '3.1 Verify Docker daemon'
    $dockerReady = $false
    for ($i = 1; $i -le 12; $i++) {
        try {
            $svc = Get-Service docker -ErrorAction SilentlyContinue
            if (-not $svc -or $svc.Status -ne 'Running') {
                Write-Log "Docker not running, starting... (attempt $i)"
                Start-Service docker -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 10
                continue
            }
            $null = docker info 2>&1
            if ($LASTEXITCODE -eq 0) { $dockerReady = $true; Write-Log 'Docker daemon is ready'; break }
        }
        catch { Write-LogWarn "Docker check attempt $i failed: $_" }
        Write-Log "Waiting for Docker... (attempt $i/12)"
        Start-Sleep -Seconds 10
    }
    if (-not $dockerReady) { Write-LogError 'FATAL: Docker not ready after 2 minutes'; exit 1 }

    $dockerVersion   = docker version --format '{{.Server.Version}}' 2>$null
    $dockerIsolation = docker info --format '{{.Isolation}}' 2>$null
    Write-Log "Docker: version=$dockerVersion isolation=$dockerIsolation"

    # -- 3.2 Defender configuration ----------------------------
    Write-Log '3.2 Configure Windows Defender (exclusions + scheduled scan only)'

    # Path exclusions -- high-I/O directories
    foreach ($p in @($Script:Config.RunnerDir, $Script:Config.DockerConfigDir,
                     $Script:Config.DockerDir, $Script:Config.BuildsDir,
                     $Script:Config.CacheDir, $Script:Config.DockerDataRoot)) {
        try { Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue }
        catch { Write-LogWarn "Defender path exclusion failed: $p" }
    }

    # Process exclusions -- runner and Docker binaries
    foreach ($p in @('gitlab-runner.exe', 'dockerd.exe', 'docker.exe', 'containerd.exe', 'git.exe')) {
        try { Add-MpPreference -ExclusionProcess $p -ErrorAction SilentlyContinue }
        catch { Write-LogWarn "Defender process exclusion failed: $p" }
    }

    # Disable real-time monitoring -- CI runner I/O is too heavy for continuous scanning.
    # Defender stays installed; scheduled scan runs nightly instead.
    try {
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
        Write-Log 'Defender real-time monitoring DISABLED (scheduled scan only)'
    } catch { Write-LogWarn "Failed to disable real-time monitoring: $_" }

    # Schedule full scan at 02:00 daily (ScanScheduleQuickScanTime = minutes from midnight)
    try {
        Set-MpPreference -ScanScheduleQuickScanTime 120 -ErrorAction SilentlyContinue
        Set-MpPreference -ScanParameters 2 -ErrorAction SilentlyContinue           # 2 = Full scan
        Set-MpPreference -RemediationScheduleDay 0 -ErrorAction SilentlyContinue   # 0 = Every day
        Set-MpPreference -RemediationScheduleTime 120 -ErrorAction SilentlyContinue # 02:00
        Set-MpPreference -ScanScheduleDay 0 -ErrorAction SilentlyContinue          # 0 = Every day
        Set-MpPreference -ScanScheduleTime 120 -ErrorAction SilentlyContinue       # 02:00
        Write-Log 'Defender scheduled scan set to 02:00 daily (full scan)'
    } catch { Write-LogWarn "Failed to configure scheduled scan: $_" }

    # -- 3.3 MinGit -------------------------------------------
    Write-Log '3.3 MinGit'
    Install-S3Archive -S3Key $Script:Config.S3Keys.MinGitZip `
        -DestDir $Script:Config.GitDir `
        -TestFile (Join-Path $Script:Config.GitDir 'cmd\git.exe') `
        -Label 'MinGit' | Out-Null

    # -- 3.4 GitLab Runner binary -----------------------------
    Write-Log '3.4 GitLab Runner binary'
    if (-not (Install-S3Binary -S3Key $Script:Config.S3Keys.RunnerBin -DestPath $Script:Config.RunnerBin -Label 'GitLab Runner')) {
        Write-LogError 'FATAL: Runner binary download failed'; exit 1
    }

    # -- 3.5 Pre-pull Harbor images (parallel background) -----
    # Each docker pull is a separate process talking to dockerd. Running them
    # as concurrent Start-Job background jobs lets the network downloads
    # overlap, and Docker's daemon will interleave the layer extracts as
    # disk I/O permits. Net win for cold provision: 30-50% time reduction
    # on the pull phase.
    #
    # Jobs start NOW (right after Docker verify). Steps 3.6 - 3.14 run
    # in the foreground in parallel. We Wait-Job just before final
    # validation, so the longest pull caps total Phase 3 time instead of
    # serialising with everything else.
    #
    # docker login (if creds set) MUST happen before the jobs start --
    # auth is persisted to %USERPROFILE%/.docker/config.json which the
    # child PowerShell processes inherit via the shared filesystem.
    Write-Log '3.5 Pre-pull container images (parallel background jobs)'
    if ($Script:Config.HarborUser -and $Script:Config.HarborPass) {
        Write-Log 'Logging into Harbor...'
        $Script:Config.HarborPass | docker login $Script:Config.HarborUrl -u $Script:Config.HarborUser --password-stdin 2>&1 |
            ForEach-Object { Write-Log "  docker login: $_" }
    }

    $Script:PrePullJobs   = @()
    $Script:PrePullStartT = Get-Date
    foreach ($image in $Script:Config.PrePullImages) {
        $shortName = ($image -split '/')[-1] -replace ':', '-'
        $jobName   = "prepull-$shortName"
        $Script:PrePullJobs += Start-Job -Name $jobName -ArgumentList $image -ScriptBlock {
            param($Image)
            $output = docker pull $Image 2>&1
            [PSCustomObject]@{
                Image    = $Image
                ExitCode = $LASTEXITCODE
                Output   = ($output | Out-String)
            }
        }
        Write-Log "  Started: $jobName ($image)"
    }
    Write-Log "  $($Script:PrePullJobs.Count) parallel pull job(s) running in background -- continuing with other Phase 3 work..."
    Write-Log ''

    # -- 3.6 Write config.toml --------------------------------
    Write-Log '3.6 Resolve runner token + write config.toml'

    # Token resolution: env var -> Machine env -> FATAL
    # Supports two formats:
    #   glrt-XXXX   = Runner Authentication Token (GitLab 16.0+, already registered)
    #   glrt- prefix means the runner was created via UI/API and this IS the auth token
    #   Anything else = treated as Registration Token (legacy) or PAT
    $runnerToken = $env:GITLAB_RUNNER_TOKEN
    if (-not $runnerToken) { $runnerToken = [System.Environment]::GetEnvironmentVariable('GITLAB_RUNNER_TOKEN', 'Machine') }
    if (-not $runnerToken) {
        Write-LogError 'FATAL: GITLAB_RUNNER_TOKEN not found.'
        Write-LogError '  Set as env var or Machine-level variable before running.'
        Write-LogError '  Accepted formats: glrt-XXXX (auth token) or PAT/registration token.'
        exit 1
    }

    $isAuthToken = $runnerToken -match '^glrt-'
    if ($isAuthToken) {
        Write-Log "Token type: Runner Authentication Token (glrt-***)"
    } else {
        Write-Log "Token type: Registration Token / PAT (will register first)"
    }

    $hostname   = $env:COMPUTERNAME

    # NOTE: dns deliberately omitted from [runners.docker]:
    #   process isolation inherits host DNS (domain-joined via Be1)

    $buildsVol = "$($Script:Config.BuildsDir -replace '\\','\\'):C:\\builds"
    $cacheVol  = "$($Script:Config.CacheDir  -replace '\\','\\'):C:\\cache"
    $defaultImage = "$($Script:Config.HarborUrl)/$($Script:Config.HarborProject)/servercore:ltsc2019"
    $scriptsEsc   = $Script:Config.ScriptsDir -replace '\\', '\\'

    # -- 3.7 Register runner (if not already auth token) ------
    if ($isAuthToken) {
        Write-Log '3.7 Skip registration -- glrt- token is already authenticated'
    } else {
        Write-Log '3.7 Register runner with GitLab (registration token / PAT)'
        & $Script:Config.RunnerBin register `
            --non-interactive `
            --url $Script:Config.GitLabUrl `
            --registration-token $runnerToken `
            --executor docker-windows `
            --docker-image $defaultImage `
            --tls-ca-file "" `
            --name "runner-$hostname" 2>&1 | ForEach-Object { Write-Log "  register: $_" }

        if ($LASTEXITCODE -eq 0) {
            Write-Log 'Registration successful -- extracting auth token from config.toml'
            # After registration, gitlab-runner writes the real auth token to config.toml
            # Extract it so our config.toml rewrite uses the correct token
            $regConfig = Get-Content $Script:Config.ConfigToml -Raw -ErrorAction SilentlyContinue
            if ($regConfig -match 'token\s*=\s*"(glrt-[^"]+)"') {
                $runnerToken = $Matches[1]
                Write-Log "Extracted auth token: glrt-***"
            } else {
                Write-LogError 'Registration returned 0 but no glrt- token found in config.toml.'
                Write-LogError 'Original token (PAT/legacy) is NOT a valid runner auth token -- aborting.'
                $Script:RunnerRegistrationFailed = $true
            }
        } else {
            Write-LogError 'Runner registration FAILED (non-zero exit).'
            Write-LogError 'The provided token is NOT a valid runner auth token -- runner will NOT connect.'
            Write-LogError 'Re-run with a valid glrt- token or fix GitLab connectivity and re-register.'
            $Script:RunnerRegistrationFailed = $true
        }
    }

    # -- Gate: abort runner config/service if registration failed --
    if ($Script:RunnerRegistrationFailed) {
        Write-LogError '3.7 SKIPPING config.toml write + service install -- registration failed'
        Write-LogError '    Fix: supply a valid glrt- token or restore GitLab connectivity, then re-run Phase 3'
    } else {
        # Write (or overwrite) config.toml with our full config
        $configContent = @"
# GitLab Runner Configuration -- Auto-generated
# Host: $hostname | Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

concurrent = $($Script:Config.ConcurrentJobs)
check_interval = $($Script:Config.CheckInterval)
shutdown_timeout = 300
log_level = "info"

# Prometheus metrics endpoint (consumed by the observability stack).
# Firewall hole opened by Install-Observability.ps1.
listen_address = ":$($Script:Config.MetricsPorts.GitLabRunner)"

[[runners]]
  name = "runner-$hostname"
  url = "$($Script:Config.GitLabUrl)"
  token = "$runnerToken"
  executor = "docker-windows"
  tls-verify = false
  environment = ["GIT_SSL_NO_VERIFY=true", "DOCKER_TLS_CERTDIR="]
  pre_build_script = "powershell -NoProfile -ExecutionPolicy Bypass -File ${scriptsEsc}\\Write-JobLog.ps1 -Action start"
  post_build_script = "powershell -NoProfile -ExecutionPolicy Bypass -File ${scriptsEsc}\\Write-JobLog.ps1 -Action end"

  [runners.docker]
    image = "$defaultImage"
    helper_image = "$($Script:Config.HelperImage)"
    isolation = "process"
    pull_policy = ["if-not-present"]
    tls_verify = false
    privileged = false
    shm_size = 268435456
    volumes = ["$buildsVol", "$cacheVol"]
    allowed_images = []
    allowed_services = []
    wait_for_services_timeout = 30
    disable_cache = false

  [runners.cache]
    Type = ""
"@
        $configContent | Out-File -FilePath $Script:Config.ConfigToml -Encoding UTF8 -Force
        Write-Log 'config.toml written'

        # -- 3.8 Install runner service (idempotent) --------------
        # Only call stop/uninstall when the service actually exists -- otherwise
        # gitlab-runner emits FATAL log lines ("service does not exist") that
        # look like real failures during first-time install. The actual install
        # + start is what matters.
        Write-Log '3.8 Install runner service'
        if (Get-Service gitlab-runner -ErrorAction SilentlyContinue) {
            Write-Log '  Existing gitlab-runner service detected -- stopping and uninstalling first'
            & $Script:Config.RunnerBin stop      2>&1 | ForEach-Object { Write-Log "  stop: $_" }
            & $Script:Config.RunnerBin uninstall 2>&1 | ForEach-Object { Write-Log "  uninstall: $_" }
            Start-Sleep -Seconds 2
        } else {
            Write-Log '  No existing gitlab-runner service -- proceeding to install'
        }
        & $Script:Config.RunnerBin install `
            --working-directory $Script:Config.RunnerDir `
            --config $Script:Config.ConfigToml 2>&1 |
            ForEach-Object { Write-Log "  install: $_" }
        & $Script:Config.RunnerBin start 2>&1 | ForEach-Object { Write-Log "  start: $_" }

        if (Wait-ServiceRunning -Name 'gitlab-runner' -TimeoutSeconds 30 -PollSeconds 3) {
            Write-Log 'GitLab Runner service is RUNNING'
        } else {
            Write-LogError 'GitLab Runner service failed to start'
            $Script:RunnerRegistrationFailed = $true
        }
    }

    # -- 3.9 Deploy maintenance scripts -----------------------
    Write-Log '3.9 Deploy maintenance scripts'
    $s3Failures = 0
    $s3Skipped  = 0
    foreach ($s in @(
        @{ Key = $Script:Config.S3Keys.HealthCheck; File = 'health-check.ps1' },
        @{ Key = $Script:Config.S3Keys.DiskMonitor;  File = 'disk-monitor.ps1' },
        @{ Key = $Script:Config.S3Keys.DockerWdog;   File = 'docker-watchdog.ps1' },
        @{ Key = $Script:Config.S3Keys.KillStale;    File = 'kill-stale-containers.ps1' },
        @{ Key = $Script:Config.S3Keys.RegTasks;     File = 'Register-ScheduledTasks.ps1' }
    )) {
        $outPath = Join-Path $Script:Config.ScriptsDir $s.File
        # Skip re-fetch if a previous phase already deposited it on disk
        # (e.g. Import-Certificates.ps1 from Phase 1 step 1.10). Saves
        # one S3 round-trip per file -- meaningful when sync runs across
        # several phases and an MinIO call costs ~100ms.
        if ((Test-Path $outPath) -and ((Get-Item $outPath).Length -gt 0)) {
            $s3Skipped++
            continue
        }
        try {
            Get-S3Object -Key $s.Key -OutFile $outPath | Out-Null
            if (-not (Test-Path $outPath)) { throw "File not created: $outPath" }
        } catch {
            Write-LogWarn "Failed to download $($s.File): $_"
            $s3Failures++
        }
    }

    # Deploy new feature scripts (Import-Certificates already on disk from
    # Phase 1 -- skip-if-exists below avoids the duplicate S3 fetch).
    foreach ($s in @(
        @{ Key = $Script:Config.S3KeysExtra.ImportCerts;          File = 'Import-Certificates.ps1' },
        @{ Key = $Script:Config.S3KeysExtra.EnableRemoteSSH;      File = 'Enable-RemoteSSH.ps1' },
        @{ Key = $Script:Config.S3KeysExtra.NetMonitor;           File = 'Test-NetworkConnectivity.ps1' },
        @{ Key = $Script:Config.S3KeysExtra.JobLog;               File = 'Write-JobLog.ps1' },
        @{ Key = $Script:Config.S3KeysExtra.RdpAudit;             File = 'Export-RdpAuditLog.ps1' },
        @{ Key = $Script:Config.S3KeysExtra.LogCollector;         File = 'Export-RunnerLogs.ps1' },
        @{ Key = $Script:Config.S3KeysExtra.GoldenVersion;        File = 'Write-GoldenVersion.ps1' },
        @{ Key = $Script:Config.S3KeysExtra.InstallOpenCode;      File = 'Install-OpenCode.ps1' },
        @{ Key = $Script:Config.S3KeysExtra.InstallTools;         File = 'Install-Tools.ps1' },
        @{ Key = $Script:Config.S3KeysExtra.InstallObservability; File = 'Install-Observability.ps1' },
        @{ Key = $Script:Config.S3KeysExtra.SetWtDefault;         File = 'Set-WindowsTerminalDefault.ps1' }
    )) {
        $outPath = Join-Path $Script:Config.ScriptsDir $s.File
        if ((Test-Path $outPath) -and ((Get-Item $outPath).Length -gt 0)) {
            $s3Skipped++
            continue
        }
        try {
            Get-S3Object -Key $s.Key -OutFile $outPath | Out-Null
            if (-not (Test-Path $outPath)) { throw "File not created: $outPath" }
        } catch {
            Write-LogWarn "Failed to download $($s.File): $_"
            $s3Failures++
        }
    }
    if ($s3Skipped -gt 0) {
        Write-Log "  $s3Skipped script(s) already on disk -- skipped re-fetch"
    }
    if ($s3Failures -gt 0) {
        Write-LogError "S3 script deployment: $s3Failures file(s) failed -- maintenance scripts/tasks would be broken"
        $Script:ProvisioningFailed = $true
    }
    # Create log subdirectories
    foreach ($d in @($Script:Config.JobLogDir, $Script:Config.NetLogDir, $Script:Config.RdpLogDir)) {
        if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
    }

    # -- 3.10 Deploy monitor-hosts.json -----------------------
    Write-Log '3.10 Deploy monitor-hosts.json from Config.MonitorHosts'
    $monitorJson = ConvertTo-Json -InputObject @($Script:Config.MonitorHosts) -Depth 2
    $monitorJsonPath = Join-Path $Script:Config.ScriptsDir 'monitor-hosts.json'
    $monitorJson | Out-File -FilePath $monitorJsonPath -Encoding UTF8 -Force
    Write-Log "  Written: $monitorJsonPath"

    # -- 3.11 Register scheduled tasks ------------------------
    Write-Log '3.11 Register scheduled tasks'
    $regScript = Join-Path $Script:Config.ScriptsDir 'Register-ScheduledTasks.ps1'
    if (-not (Test-Path $regScript)) {
        Write-LogError 'FATAL: Register-ScheduledTasks.ps1 missing -- maintenance tasks not registered'
        $Script:ProvisioningFailed = $true
    } else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $regScript `
            -ScriptsDir $Script:Config.ScriptsDir `
            -LogsDir $Script:Config.LogsDir `
            -BuildsDir $Script:Config.BuildsDir 2>&1 |
            ForEach-Object { Write-Log "  tasks: $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-LogError "Register-ScheduledTasks.ps1 exited $LASTEXITCODE -- task hardening incomplete"
            $Script:ProvisioningFailed = $true
        }
    }

    # -- 3.12 Install tools (table-driven) --------------------
    # All tool installation is delegated to scripts/Install-Tools.ps1, which
    # iterates $Script:Config.ToolPackages. Add a new tool by adding a row to
    # that table; this step doesn't change.
    Write-Log '3.12 Install tools (table-driven via Install-Tools.ps1)'
    $installToolsScr = Join-Path $Script:Config.ScriptsDir 'Install-Tools.ps1'
    if (Test-Path $installToolsScr) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installToolsScr 2>&1 |
            ForEach-Object { Write-Log "  tools: $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-LogWarn "Install-Tools.ps1 reported $LASTEXITCODE failures -- runner is still operational"
        }
    } else {
        Write-LogWarn 'Install-Tools.ps1 not found -- skipping tool deployment'
    }

    # -- 3.13 OpenCode (WebView2 prereq + silent install + machine config) ---
    # All real work lives in scripts/Install-OpenCode.ps1 -- here we only
    # stage the binaries from S3 and invoke that script. Keeps Phase 3 small.
    Write-Log '3.13 Install OpenCode (with WebView2 prerequisite)'

    if (-not (Test-Path $Script:Config.WebView2StageDir)) {
        New-Item -Path $Script:Config.WebView2StageDir -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path $Script:Config.OpenCodeStageDir)) {
        New-Item -Path $Script:Config.OpenCodeStageDir -ItemType Directory -Force | Out-Null
    }

    Get-S3Object -Key $Script:Config.S3KeysExtra.WebView2Exe    -OutFile $Script:Config.WebView2InstallerLocal | Out-Null
    Get-S3Object -Key $Script:Config.S3KeysExtra.OpenCodeExe    -OutFile $Script:Config.OpenCodeInstallerLocal | Out-Null
    Get-S3Object -Key $Script:Config.S3KeysExtra.OpenCodeConfig -OutFile $Script:Config.OpenCodeJsoncSource    | Out-Null

    $installOpenCodeScr = Join-Path $Script:Config.ScriptsDir 'Install-OpenCode.ps1'
    if (Test-Path $installOpenCodeScr) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installOpenCodeScr `
            -WebView2Installer    $Script:Config.WebView2InstallerLocal `
            -OpenCodeInstaller    $Script:Config.OpenCodeInstallerLocal `
            -OpenCodeConfigSource $Script:Config.OpenCodeJsoncSource `
            -MachineConfigPath    $Script:Config.OpenCodeMachineFile 2>&1 |
            ForEach-Object { Write-Log "  opencode: $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-LogWarn "Install-OpenCode.ps1 exited $LASTEXITCODE -- runner is functional but OpenCode may not be."
        }
    } else {
        Write-LogWarn 'Install-OpenCode.ps1 not found -- skipping OpenCode install'
    }

    # -- 3.14 Install observability stack ---------------------
    # windows_exporter (host metrics) + blackbox_exporter (probes) + firewall
    # holes for runner :9252 and Docker :9323 metrics. Must run AFTER
    # Install-Tools.ps1 because blackbox_exporter is registered as a service
    # via NSSM, which Install-Tools provides.
    Write-Log '3.14 Install observability stack'
    $installObsScr = Join-Path $Script:Config.ScriptsDir 'Install-Observability.ps1'
    if (Test-Path $installObsScr) {
        $wxLocal = $Script:Config.ObservabilityPackages.WindowsExporter.LocalPath
        $bbLocal = $Script:Config.ObservabilityPackages.BlackboxExporter.LocalPath

        # Stage installers from MinIO
        if (-not (Test-Path (Split-Path $wxLocal))) { New-Item -Path (Split-Path $wxLocal) -ItemType Directory -Force | Out-Null }
        if (-not (Test-Path (Split-Path $bbLocal))) { New-Item -Path (Split-Path $bbLocal) -ItemType Directory -Force | Out-Null }
        Get-S3Object -Key $Script:Config.ObservabilityPackages.WindowsExporter.S3Key  -OutFile $wxLocal | Out-Null
        Get-S3Object -Key $Script:Config.ObservabilityPackages.BlackboxExporter.S3Key -OutFile $bbLocal | Out-Null

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installObsScr `
            -WindowsExporterMsi   $wxLocal `
            -BlackboxExporterZip  $bbLocal `
            -BlackboxInstallDir   $Script:Config.ObservabilityPackages.BlackboxExporter.InstallDir `
            -WindowsExporterPort  $Script:Config.MetricsPorts.WindowsExporter `
            -BlackboxExporterPort $Script:Config.MetricsPorts.BlackboxExporter `
            -RunnerMetricsPort    $Script:Config.MetricsPorts.GitLabRunner `
            -DockerMetricsPort    $Script:Config.MetricsPorts.Docker 2>&1 |
            ForEach-Object { Write-Log "  obs: $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-LogError "Install-Observability.ps1 exited $LASTEXITCODE -- observability stack degraded"
            $Script:ProvisioningFailed = $true
        }
    } else {
        Write-LogWarn 'Install-Observability.ps1 not found -- skipping observability stack'
    }

    # -- 3.14.5 Wait for the pre-pull jobs that were started in step 3.5
    # to finish. By this point steps 3.6 - 3.14 have all run in the
    # foreground in parallel with the pulls. The longest single pull
    # caps total Phase 3 wall time.
    if ($Script:PrePullJobs -and $Script:PrePullJobs.Count -gt 0) {
        Write-Log ''
        Write-Log "Waiting for $($Script:PrePullJobs.Count) pre-pull job(s) (started in step 3.5)..."
        $pullResults = $Script:PrePullJobs | Wait-Job | ForEach-Object {
            $r = Receive-Job -Job $_
            Remove-Job -Job $_
            $r
        }
        $pullElapsed = ((Get-Date) - $Script:PrePullStartT).TotalSeconds
        Write-Log "  All pre-pull jobs done. Wall time since step 3.5 start: $([math]::Round($pullElapsed,1))s"

        $pullFailures = 0
        foreach ($r in $pullResults) {
            $tail = ($r.Output -split "`n" | Where-Object { $_ } | Select-Object -Last 3)
            if ($r.ExitCode -eq 0) {
                Write-Log "  [OK]   $($r.Image)"
                $tail | ForEach-Object { Write-Log "    $_" }
            } else {
                Write-LogError "  [FAIL] $($r.Image) (exit $($r.ExitCode))"
                $tail | ForEach-Object { Write-LogError "    $_" }
                $pullFailures++
            }
        }
        if ($pullFailures -gt 0) {
            Write-LogError "FATAL: $pullFailures Harbor image(s) failed to pull. In air-gapped environment images must be pre-pulled."
            Write-LogError '  Verify Harbor connectivity, credentials, and that images exist in the registry.'
            exit 1
        }
    }

    # -- 3.15 Final validation --------------------------------
    Write-Log '========== FINAL VALIDATION =========='
    Invoke-FinalValidation
    if ($Script:ProvisioningFailed) {
        Write-LogError 'Final validation reported one or more failed checks -- runner will be marked DEGRADED.'
    }

    # -- 3.16 Write golden image version stamp ----------------
    Write-Log '3.16 Write golden image version stamp'
    $versionScript = Join-Path $Script:Config.ScriptsDir 'Write-GoldenVersion.ps1'
    if (Test-Path $versionScript) {
        & $versionScript `
            -ImageVersion $Script:Config.GoldenImageVersion `
            -OutputPath (Join-Path $Script:Config.RunnerDir '.golden-version') `
            -RunnerBin $Script:Config.RunnerBin `
            -GitExe (Join-Path $Script:Config.GitDir 'cmd\git.exe') `
            -CertsDir $Script:Config.CertsDir 2>&1 |
            ForEach-Object { Write-Log "  version: $_" }
    } else {
        Write-LogWarn 'Write-GoldenVersion.ps1 not found -- skipping version stamp'
    }

    if ($Script:RunnerRegistrationFailed -or $Script:ProvisioningFailed) {
        Write-LogError '========== PHASE 3 COMPLETE -- RUNNER IS DEGRADED =========='
        Write-LogError 'Exiting with code 1 so Be1 knows this VM is NOT operational.'
        exit 1
    } else {
        Set-PhaseMarker $Script:Config.Phase3Marker
        Write-Log '========== PHASE 3 COMPLETE -- RUNNER IS OPERATIONAL =========='
    }
}
