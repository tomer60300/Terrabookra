<#
.SYNOPSIS
    Phase 3 (BUILD-TIME) -- Docker verify, runner binary install, image pre-pull,
    maintenance + tooling + observability, config.toml skeleton, build-gate.

.DESCRIPTION
    Build-time golden-image installation. Produces a GENERIC,
    UNREGISTERED golden image: the runner binary is installed and a token-LESS
    config.toml skeleton is written, but NO token is resolved, NO registration is
    performed, and the runner Windows service is NOT installed or started. Those
    per-clone steps run at first boot (provisioners/Register-RunnerFirstBoot.ps1)
    from the guestinfo-delivered token + hostname.

    Artifacts are read from the uploaded repo tree (Packer `file` provisioner),
    not MinIO -- via Copy-RepoFile / Install-LocalBinary / Install-LocalArchive.
    Container images come from the GitLab Container Registry (Harbor retired).

    Steps:
      3.1   Verify Docker daemon (12 attempts)
      3.2   Configure Windows Defender (exclusions + scheduled scan)
      3.3   Install MinGit                         (local archive)
      3.4   Install GitLab Runner binary           (local binary)
      3.5   GitLab registry login + pre-pull images (parallel background jobs)
      3.6   Write config.toml SKELETON (token-less; finalized at first boot)
      3.9   Deploy maintenance + feature scripts   (local copy)
      3.10  Deploy monitor-hosts.json
      3.11  Register scheduled tasks
      3.12  Install tools (table-driven via Install-Tools.ps1)
      3.13  Install OpenCode (+ WebView2 prerequisite)
      3.14  Install observability stack
      3.14.5 Wait for pre-pull jobs (started in 3.5)
      3.14.7 Runner VM theme (cosmetic, non-blocking)
      3.15  Build-gate validation (Invoke-FinalValidation -- image-correctness)
      3.16  Write golden image version stamp

.NOTES
    File: phases/Phase3-Install.ps1
    Requires: lib/Config.ps1, lib/Common.ps1, validation/Invoke-FinalValidation.ps1
    Invoked by: provisioners/Invoke-Phase.ps1 -Phase 3 (Packer build).
#>

function Invoke-Phase3Install {
    Write-Log '========== PHASE 3 (BUILD): Runner image install & validation =========='
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
            & { $ErrorActionPreference = 'Continue'; docker info 2>&1 | Out-Null }
            if ($LASTEXITCODE -eq 0) { $dockerReady = $true; Write-Log 'Docker daemon is ready'; break }
        }
        catch { Write-LogWarn "Docker check attempt $i failed: $_" }
        Write-Log "Waiting for Docker... (attempt $i/12)"
        Start-Sleep -Seconds 10
    }
    if (-not $dockerReady) { Write-LogError 'FATAL: Docker not ready after 2 minutes'; exit 1 }

    $dockerVersion   = & { $ErrorActionPreference = 'Continue'; docker version --format '{{.Server.Version}}' 2>$null }
    $dockerIsolation = & { $ErrorActionPreference = 'Continue'; docker info --format '{{.Isolation}}' 2>$null }
    Write-Log "Docker: version=$dockerVersion isolation=$dockerIsolation"

    # -- 3.2 Defender configuration ----------------------------
    Write-Log '3.2 Configure Windows Defender (exclusions + scheduled scan only)'

    foreach ($p in @($Script:Config.RunnerDir, $Script:Config.DockerConfigDir,
                     $Script:Config.DockerDir, $Script:Config.BuildsDir,
                     $Script:Config.CacheDir, $Script:Config.DockerDataRoot)) {
        try { Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue }
        catch { Write-LogWarn "Defender path exclusion failed: $p" }
    }
    foreach ($p in @('gitlab-runner.exe', 'dockerd.exe', 'docker.exe', 'containerd.exe', 'git.exe')) {
        try { Add-MpPreference -ExclusionProcess $p -ErrorAction SilentlyContinue }
        catch { Write-LogWarn "Defender process exclusion failed: $p" }
    }
    try {
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
        Write-Log 'Defender real-time monitoring DISABLED (scheduled scan only)'
    } catch { Write-LogWarn "Failed to disable real-time monitoring: $_" }
    try {
        Set-MpPreference -ScanScheduleQuickScanTime 120 -ErrorAction SilentlyContinue
        Set-MpPreference -ScanParameters 2 -ErrorAction SilentlyContinue
        Set-MpPreference -RemediationScheduleDay 0 -ErrorAction SilentlyContinue
        Set-MpPreference -RemediationScheduleTime 120 -ErrorAction SilentlyContinue
        Set-MpPreference -ScanScheduleDay 0 -ErrorAction SilentlyContinue
        Set-MpPreference -ScanScheduleTime 120 -ErrorAction SilentlyContinue
        Write-Log 'Defender scheduled scan set to 02:00 daily (full scan)'
    } catch { Write-LogWarn "Failed to configure scheduled scan: $_" }

    # -- 3.3 MinGit (from uploaded repo) ----------------------
    Write-Log '3.3 MinGit'
    Install-LocalArchive -RelPath $Script:Config.S3Keys.MinGitZip `
        -DestDir $Script:Config.GitDir `
        -TestFile (Join-Path $Script:Config.GitDir 'cmd\git.exe') `
        -Label 'MinGit' | Out-Null

    # -- 3.4 GitLab Runner binary (from uploaded repo) --------
    Write-Log '3.4 GitLab Runner binary'
    if (-not (Install-LocalBinary -RelPath $Script:Config.S3Keys.RunnerBin -DestPath $Script:Config.RunnerBin -Label 'GitLab Runner')) {
        Write-LogError 'FATAL: Runner binary install failed'; exit 1
    }

    # -- 3.4b Stage runtime modules to a STABLE on-image path -
    # Deployed clones run Register-RunnerFirstBoot.ps1 from C:\GitLab-Runner\scripts
    # and must find lib/ + validation/ WITHOUT C:\provision (a build-only upload
    # that may be cleaned). Stage them under C:\GitLab-Runner so the image is
    # self-contained at first boot.
    Write-Log '3.4b Stage lib/ + validation to C:\GitLab-Runner (self-contained image)'
    foreach ($pair in @(
        @{ Rel = 'lib/Config.ps1';                        Out = (Join-Path $Script:Config.RunnerDir 'lib\Config.ps1') },
        @{ Rel = 'lib/Common.ps1';                        Out = (Join-Path $Script:Config.RunnerDir 'lib\Common.ps1') },
        @{ Rel = 'validation/Invoke-FinalValidation.ps1'; Out = (Join-Path $Script:Config.RunnerDir 'validation\Invoke-FinalValidation.ps1') }
    )) {
        if (-not (Copy-RepoFile -RelPath $pair.Rel -OutFile $pair.Out)) {
            Write-LogError "FATAL: could not stage $($pair.Rel) -- deployed clones could not self-register"
            $Script:ProvisioningFailed = $true
        }
    }

    # -- 3.5 GitLab registry login + pre-pull images ----------
    # Images now come from the GitLab Container Registry (Harbor retired). The
    # base/helper images are pulled at build time so deployed runners have them
    # cached locally (air-gap). NOTE: this runs as the Packer SSH user
    # (Administrator), so this login only populates THAT user's .docker\config.json
    # -- enough to pre-pull here. The runner SERVICE runs as SYSTEM and logs in
    # again at first boot (Register-RunnerFirstBoot.ps1) for runtime pulls.
    Write-Log '3.5 GitLab registry login + pre-pull container images'
    if ($Script:Config.GitLabRegistryUser -and $Script:Config.GitLabRegistryPass) {
        $glReg = $Script:Config.GitLabRegistry
        Write-Log "Logging into GitLab registry $glReg as '$($Script:Config.GitLabRegistryUser)'..."
        $glOut  = & { $ErrorActionPreference = 'Continue'; $Script:Config.GitLabRegistryPass |
                  docker login $glReg -u $Script:Config.GitLabRegistryUser --password-stdin 2>&1 }
        $glCode = $LASTEXITCODE
        $glOut | ForEach-Object { Write-Log "  docker login: $_" }
        if ($glCode -eq 0) {
            Write-Log "GitLab registry login OK ($glReg)"
        } else {
            Write-LogWarn "GitLab registry login FAILED (exit $glCode) -- pre-pull will likely fail; the build-gate then fails on the missing helper image."
            Write-LogWarn "  Registry : $glReg"
            Write-LogWarn "  User     : $($Script:Config.GitLabRegistryUser)  (password redacted)"
            Write-LogWarn "  Output   : $(($glOut | Out-String).Trim())"
            $glHost = ($glReg -split ':')[0]
            $glPort = if ($glReg -match ':(\d+)$') { [int]$Matches[1] } else { 443 }
            try {
                $glDns = [System.Net.Dns]::GetHostAddresses($glHost) | ForEach-Object { $_.IPAddressToString }
                Write-LogWarn "  DNS      : $glHost -> $($glDns -join ', ')"
            } catch { Write-LogWarn "  DNS      : $glHost -> RESOLVE FAILED ($($_.Exception.Message))" }
            try {
                $glTcp = New-Object System.Net.Sockets.TcpClient
                $glAr  = $glTcp.BeginConnect($glHost, $glPort, $null, $null)
                $glOk  = $glAr.AsyncWaitHandle.WaitOne(3000) -and $glTcp.Connected
                Write-LogWarn "  TCP      : ${glHost}:${glPort} reachable = $glOk"
                $glTcp.Close()
            } catch { Write-LogWarn "  TCP      : ${glHost}:${glPort} probe error: $($_.Exception.Message)" }
            $glInfo = (& { $ErrorActionPreference = 'Continue'; docker info 2>&1 } | Out-String)
            if ($glInfo -match [regex]::Escape($glReg)) {
                Write-LogWarn "  Insecure : '$glReg' is in 'docker info' (insecure-registries OK)"
            } else {
                Write-LogWarn "  Insecure : '$glReg' NOT listed by 'docker info' -- if a TLS/x509 error appears above, that is the cause"
            }
            switch -Regex (($glOut | Out-String)) {
                'unauthorized|HTTP Basic: Access denied|access forbidden' { Write-LogWarn '  Likely   : wrong/expired token or missing read_registry. Check User = token NAME, token not revoked.' ; break }
                'denied: requested access'                                { Write-LogWarn '  Likely   : token role too low for push -- need Developer+ with write_registry scope.' ; break }
                'x509|certificate signed by unknown|tls: '                { Write-LogWarn "  Likely   : registry cert not trusted. Confirm $glReg is in daemon.json insecure-registries, or import its CA." ; break }
                'connection refused|no route to host|timeout|i/o timeout' { Write-LogWarn '  Likely   : registry service down, wrong port, or firewall blocking the registry port.' ; break }
                'no such host|name resolution|cannot resolve'             { Write-LogWarn '  Likely   : DNS/hosts entry for the registry host is missing.' ; break }
                default                                                   { Write-LogWarn '  Likely   : inspect the docker output above -- check token, scope, connectivity, and TLS.' }
            }
        }
    } else {
        Write-LogWarn 'GitLab registry login skipped (GitLabRegistryUser/Pass not set in Config) -- anonymous pull assumed.'
    }

    # Each image pulls in its OWN background job (parallel), streaming per-layer
    # progress to a dedicated log file. Windows base images are multi-GB; this is
    # the dominant cold-build cost. Waited for just before final validation.
    $Script:PrePullJobs   = @()
    $Script:PrePullStartT = Get-Date
    foreach ($image in $Script:Config.PrePullImages) {
        $shortName = ($image -split '/')[-1] -replace ':', '-'
        $jobName   = "prepull-$shortName"
        $jobLog    = Join-Path $Script:Config.LogsDir "pull-$shortName.log"
        Remove-Item $jobLog -Force -ErrorAction SilentlyContinue
        $Script:PrePullJobs += Start-Job -Name $jobName -ArgumentList $image, $jobLog -ScriptBlock {
            param($Image, $LogFile)
            $t0 = Get-Date
            "[$($t0.ToString('HH:mm:ss'))] PULL START $Image" | Out-File -FilePath $LogFile -Encoding UTF8
            docker pull $Image 2>&1 | ForEach-Object {
                "[$([DateTime]::Now.ToString('HH:mm:ss'))] $_" | Out-File -FilePath $LogFile -Append -Encoding UTF8
            }
            $ec   = $LASTEXITCODE
            $secs = [int]((Get-Date) - $t0).TotalSeconds
            "[$([DateTime]::Now.ToString('HH:mm:ss'))] PULL END exit=$ec (${secs}s)" | Out-File -FilePath $LogFile -Append -Encoding UTF8
            [PSCustomObject]@{ Image = $Image; ExitCode = $ec; Seconds = $secs; LogFile = $LogFile }
        }
        Write-Log "  Started: $jobName ($image) -> live log $jobLog"
    }
    Write-Log "  $($Script:PrePullJobs.Count) parallel pull job(s) running -- other Phase 3 work continues; waited at step 3.14.5."
    Write-Log ''

    # -- 3.6 Write config.toml SKELETON (token-less) ----------
    # GENERIC image: no token, no [[runners]] auth block, placeholder name. The
    # final config.toml (real token + name + full [[runners]]/[runners.docker]
    # block) is written at first boot by Register-RunnerFirstBoot.ps1. No runner
    # service is installed here -- a service without a valid token would crash-loop.
    Write-Log '3.6 Write config.toml skeleton (finalized at first boot)'
    $r = $Script:Config.Runner
    $skeleton = @"
# GitLab Runner config.toml -- SKELETON (generic golden image)
# This file is REPLACED at first boot by provisioners/Register-RunnerFirstBoot.ps1
# once the per-clone runner token + hostname arrive via vSphere guestinfo.
# No [[runners]] block here on purpose: the image ships UNREGISTERED.
concurrent = $($Script:Config.ConcurrentJobs)
check_interval = $($Script:Config.CheckInterval)
shutdown_timeout = $($r.ShutdownTimeout)
log_level = "$($r.LogLevel)"
listen_address = ":$($Script:Config.MetricsPorts.GitLabRunner)"
"@
    $skeleton | Out-File -FilePath $Script:Config.ConfigToml -Encoding UTF8 -Force
    Write-Log "  config.toml skeleton written to $($Script:Config.ConfigToml)"

    # -- 3.8 Install the first-boot registration startup task -
    # Bakes provisioners/Register-RunnerFirstBoot.ps1 onto the image and registers
    # it as a SYSTEM AtStartup task. At first boot on a deployed clone it reads the
    # guestinfo runner token + hostname, writes the final config.toml, registers,
    # and starts the runner service. No service is installed here -- the image
    # ships unregistered on purpose.
    Write-Log '3.8 Install first-boot registration startup task'
    $firstBootDst = Join-Path $Script:Config.ScriptsDir 'Register-RunnerFirstBoot.ps1'
    if (Copy-RepoFile -RelPath $Script:Config.S3KeysExtra.FirstBootRegister -OutFile $firstBootDst) {
        & { $ErrorActionPreference = 'Continue'; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $firstBootDst `
            -InstallStartupTask -SelfPath $firstBootDst 2>&1 } |
            ForEach-Object { Write-Log "  firstboot: $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-LogError "First-boot task install exited $LASTEXITCODE -- deployed clones would NOT self-register"
            $Script:ProvisioningFailed = $true
        }
    } else {
        Write-LogError 'FATAL: Register-RunnerFirstBoot.ps1 missing from repo -- clones cannot self-register'
        $Script:ProvisioningFailed = $true
    }

    # -- 3.9 Deploy maintenance + feature scripts (local copy) -
    Write-Log '3.9 Deploy maintenance + feature scripts from the uploaded repo'
    $s3Failures = 0
    foreach ($s in @(
        @{ Key = $Script:Config.S3Keys.HealthCheck; File = 'health-check.ps1' },
        @{ Key = $Script:Config.S3Keys.DiskMonitor;  File = 'disk-monitor.ps1' },
        @{ Key = $Script:Config.S3Keys.DockerWdog;   File = 'docker-watchdog.ps1' },
        @{ Key = $Script:Config.S3Keys.KillStale;    File = 'kill-stale-containers.ps1' },
        @{ Key = $Script:Config.S3Keys.RegTasks;     File = 'Register-ScheduledTasks.ps1' },
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
        if (-not (Copy-RepoFile -RelPath $s.Key -OutFile $outPath)) {
            Write-LogWarn "Failed to deploy $($s.File) from repo"
            $s3Failures++
        }
    }
    if ($s3Failures -gt 0) {
        Write-LogError "Script deployment: $s3Failures file(s) failed -- maintenance scripts/tasks would be broken"
        $Script:ProvisioningFailed = $true
    }
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
        & { $ErrorActionPreference = 'Continue'; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $regScript `
            -ScriptsDir $Script:Config.ScriptsDir `
            -LogsDir $Script:Config.LogsDir `
            -BuildsDir $Script:Config.BuildsDir 2>&1 } |
            ForEach-Object { Write-Log "  tasks: $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-LogError "Register-ScheduledTasks.ps1 exited $LASTEXITCODE -- task hardening incomplete"
            $Script:ProvisioningFailed = $true
        }
    }

    # -- 3.12 Install tools (table-driven) --------------------
    Write-Log '3.12 Install tools (table-driven via Install-Tools.ps1)'
    $installToolsScr = Join-Path $Script:Config.ScriptsDir 'Install-Tools.ps1'
    if (Test-Path $installToolsScr) {
        & { $ErrorActionPreference = 'Continue'; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installToolsScr 2>&1 } |
            ForEach-Object { Write-Log "  tools: $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-LogWarn "Install-Tools.ps1 reported $LASTEXITCODE failures -- runner is still operational"
        }
    } else {
        Write-LogWarn 'Install-Tools.ps1 not found -- skipping tool deployment'
    }

    # -- 3.13 OpenCode (WebView2 prereq + machine config) -----
    Write-Log '3.13 Install OpenCode (with WebView2 prerequisite)'
    if (-not (Test-Path $Script:Config.WebView2StageDir)) {
        New-Item -Path $Script:Config.WebView2StageDir -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path $Script:Config.OpenCodeStageDir)) {
        New-Item -Path $Script:Config.OpenCodeStageDir -ItemType Directory -Force | Out-Null
    }
    Copy-RepoFile -RelPath $Script:Config.S3KeysExtra.WebView2Exe    -OutFile $Script:Config.WebView2InstallerLocal | Out-Null
    Copy-RepoFile -RelPath $Script:Config.S3KeysExtra.OpenCodeExe    -OutFile $Script:Config.OpenCodeInstallerLocal | Out-Null
    Copy-RepoFile -RelPath $Script:Config.S3KeysExtra.OpenCodeConfig -OutFile $Script:Config.OpenCodeJsoncSource    | Out-Null

    $installOpenCodeScr = Join-Path $Script:Config.ScriptsDir 'Install-OpenCode.ps1'
    if (Test-Path $installOpenCodeScr) {
        & { $ErrorActionPreference = 'Continue'; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installOpenCodeScr `
            -WebView2Installer    $Script:Config.WebView2InstallerLocal `
            -OpenCodeInstaller    $Script:Config.OpenCodeInstallerLocal `
            -OpenCodeConfigSource $Script:Config.OpenCodeJsoncSource `
            -MachineConfigPath    $Script:Config.OpenCodeMachineFile 2>&1 } |
            ForEach-Object { Write-Log "  opencode: $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-LogWarn "Install-OpenCode.ps1 exited $LASTEXITCODE -- runner is functional but OpenCode may not be."
        }
    } else {
        Write-LogWarn 'Install-OpenCode.ps1 not found -- skipping OpenCode install'
    }

    # -- 3.14 Install observability stack ---------------------
    Write-Log '3.14 Install observability stack'
    $installObsScr = Join-Path $Script:Config.ScriptsDir 'Install-Observability.ps1'
    if (Test-Path $installObsScr) {
        $wxLocal = $Script:Config.ObservabilityPackages.WindowsExporter.LocalPath
        $bbLocal = $Script:Config.ObservabilityPackages.BlackboxExporter.LocalPath
        if (-not (Test-Path (Split-Path $wxLocal))) { New-Item -Path (Split-Path $wxLocal) -ItemType Directory -Force | Out-Null }
        if (-not (Test-Path (Split-Path $bbLocal))) { New-Item -Path (Split-Path $bbLocal) -ItemType Directory -Force | Out-Null }
        Copy-RepoFile -RelPath $Script:Config.ObservabilityPackages.WindowsExporter.S3Key  -OutFile $wxLocal | Out-Null
        Copy-RepoFile -RelPath $Script:Config.ObservabilityPackages.BlackboxExporter.S3Key -OutFile $bbLocal | Out-Null

        & { $ErrorActionPreference = 'Continue'; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installObsScr `
            -WindowsExporterMsi   $wxLocal `
            -BlackboxExporterZip  $bbLocal `
            -BlackboxInstallDir   $Script:Config.ObservabilityPackages.BlackboxExporter.InstallDir `
            -WindowsExporterPort  $Script:Config.MetricsPorts.WindowsExporter `
            -BlackboxExporterPort $Script:Config.MetricsPorts.BlackboxExporter `
            -RunnerMetricsPort    $Script:Config.MetricsPorts.GitLabRunner `
            -DockerMetricsPort    $Script:Config.MetricsPorts.Docker 2>&1 } |
            ForEach-Object { Write-Log "  obs: $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-LogError "Install-Observability.ps1 exited $LASTEXITCODE -- observability stack degraded"
            $Script:ProvisioningFailed = $true
        }
    } else {
        Write-LogWarn 'Install-Observability.ps1 not found -- skipping observability stack'
    }

    # -- 3.14.5 Wait for the pre-pull jobs started in step 3.5
    if ($Script:PrePullJobs -and $Script:PrePullJobs.Count -gt 0) {
        Write-Log ''
        Write-Log "Waiting for $($Script:PrePullJobs.Count) pre-pull job(s) (started in step 3.5)."
        $hb = 30; $next = $hb
        $running = @($Script:PrePullJobs)
        $pullResults = @()
        while ($running.Count -gt 0) {
            Start-Sleep -Seconds 5
            $elapsed = [int]((Get-Date) - $Script:PrePullStartT).TotalSeconds
            foreach ($j in @($running | Where-Object { $_.State -ne 'Running' })) {
                $rj = Receive-Job -Job $j; Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
                $pullResults += $rj
                if ($rj.ExitCode -eq 0) {
                    $szTxt = ''
                    $sz = docker image inspect $rj.Image --format '{{.Size}}' 2>$null
                    if ("$sz" -match '^\d+$') { $szTxt = (' | {0:N2} GB on disk' -f ([double]$sz / 1GB)) }
                    Write-Log "  [DONE $($rj.Seconds)s] $($rj.Image)$szTxt"
                } else {
                    Write-LogError "  [FAIL $($rj.Seconds)s] $($rj.Image) (exit $($rj.ExitCode)) -- last log lines:"
                    if (Test-Path $rj.LogFile) { Get-Content $rj.LogFile -Tail 6 | ForEach-Object { Write-LogError "      $_" } }
                }
            }
            $running = @($running | Where-Object { $_.State -eq 'Running' })
            if ($running.Count -gt 0 -and $elapsed -ge $next) {
                Write-Log "  ... still pulling after ${elapsed}s ($($running.Count) running):"
                foreach ($j in $running) {
                    $img  = ($j.Name -replace '^prepull-', '')
                    $jlog = Join-Path $Script:Config.LogsDir "pull-$img.log"
                    $last = if (Test-Path $jlog) { (Get-Content $jlog -Tail 1) } else { '(starting...)' }
                    Write-Log "      $img : $last"
                }
                $next += $hb
            }
        }
        $pullElapsed = [int]((Get-Date) - $Script:PrePullStartT).TotalSeconds
        Write-Log "  All pre-pull jobs finished in ${pullElapsed}s (since step 3.5)."
        $pullFailures = @($pullResults | Where-Object { $_.ExitCode -ne 0 }).Count
        if ($pullFailures -gt 0) {
            Write-LogError "FATAL: $pullFailures registry image(s) failed to pull. The build-gate requires the helper image to be present."
            Write-LogError '  Verify GitLab registry connectivity, credentials, and that the images exist.'
            exit 1
        }
    }

    # -- 3.14.7 Runner VM theme (cosmetic, NON-BLOCKING) ------
    Write-Log '3.14.7 Runner theme (cosmetic, non-blocking)'
    try {
        $themeScr = Join-Path $Script:Config.ScriptsDir 'Set-RunnerTheme.ps1'
        if (-not (Test-Path $themeScr)) {
            Copy-RepoFile -RelPath $Script:Config.S3KeysExtra.ThemeScript -OutFile $themeScr | Out-Null
        }
        if (Test-Path $themeScr) {
            $thPrin    = New-ScheduledTaskPrincipal -GroupId 'S-1-5-4' -RunLevel Limited
            $thAtLogon = New-ScheduledTaskTrigger -AtLogOn
            $thEvery   = New-ScheduledTaskTrigger -Once -At ((Get-Date).Date.AddMinutes(2)) -RepetitionInterval (New-TimeSpan -Minutes 20) -RepetitionDuration (New-TimeSpan -Days 3650)
            $thAct     = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$themeScr`""
            $thSet     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
            Register-ScheduledTask -TaskName 'Runner-Theme-Apply' -Action $thAct -Trigger @($thAtLogon, $thEvery) -Principal $thPrin -Settings $thSet -Force | Out-Null
            Write-Log '  Runner-Theme-Apply registered (logon + every 20 min, interactive user)'
        } else {
            Write-LogWarn '  Set-RunnerTheme.ps1 unavailable -- skipping theme (non-blocking)'
        }
    } catch {
        Write-LogWarn "  Theme setup failed (non-blocking, ignored): $($_.Exception.Message)"
    }

    # -- 3.15 Build-gate validation ---------------------------
    # Image-correctness subset. The deploy/first-boot gate (runner registered +
    # service running + verify) is Test-RunnerRegistered, run at first boot.
    Write-Log '========== BUILD-GATE VALIDATION =========='
    Invoke-FinalValidation
    if ($Script:ProvisioningFailed) {
        Write-LogError 'Build-gate reported one or more failed checks -- image is NOT shippable.'
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

    if ($Script:ProvisioningFailed) {
        Write-LogError '========== PHASE 3 (BUILD) FAILED -- IMAGE NOT SHIPPABLE =========='
        Write-LogError 'Exiting 1 so Packer fails the build.'
        exit 1
    } else {
        Set-PhaseMarker $Script:Config.Phase3Marker
        Write-Log '========== PHASE 3 (BUILD) COMPLETE -- GENERIC IMAGE READY (UNREGISTERED) =========='
    }
}
