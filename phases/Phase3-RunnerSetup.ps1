<#
.SYNOPSIS
    Phase 3 — Docker verify, runner install, registration, maintenance, validation.

.DESCRIPTION
    Called after Phase 2 marker is detected. Final phase — no reboot after this.

    3.1   Verify Docker daemon (12 attempts)
    3.2   Add Defender exclusions
    3.3   Install MinGit
    3.4   Download GitLab Runner binary
    3.5   Pre-pull Harbor container images
    3.6   Resolve token (glrt- auth token vs registration token / PAT)
    3.7   Register runner (skipped if glrt- token) + write config.toml
    3.8   Install runner as Windows service
    3.9   Deploy maintenance scripts from MinIO
    3.10  Register scheduled tasks
    3.11  Deploy tools (WinRAR, NSSM, SysInternals, OpenCode)
    3.12  Final validation (17 checks)
    3.13  Write golden image version stamp

.NOTES
    File: phases/Phase3-RunnerSetup.ps1
    Requires: lib/Config.ps1, lib/Common.ps1, validation/Invoke-FinalValidation.ps1
#>

function Invoke-Phase3 {
    Write-Log '========== PHASE 3: Runner Setup & Configuration =========='

    # ── 3.1 Verify Docker daemon ─────────────────────────────
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

    # ── 3.2 Defender exclusions ──────────────────────────────
    Write-Log '3.2 Defender exclusions'
    foreach ($p in @('C:\GitLab-Runner', 'C:\ProgramData\docker', 'C:\Program Files\Docker',
                     $Script:Config.BuildsDir, $Script:Config.CacheDir, $Script:Config.DockerDataRoot)) {
        try { Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue }
        catch { Write-LogWarn "Defender path exclusion failed: $p" }
    }
    foreach ($p in @('gitlab-runner.exe', 'dockerd.exe', 'docker.exe', 'containerd.exe', 'git.exe')) {
        try { Add-MpPreference -ExclusionProcess $p -ErrorAction SilentlyContinue }
        catch { Write-LogWarn "Defender process exclusion failed: $p" }
    }

    # ── 3.3 MinGit ───────────────────────────────────────────
    Write-Log '3.3 MinGit'
    Install-S3Archive -S3Key $Script:Config.S3Keys.MinGitZip `
        -DestDir $Script:Config.GitDir `
        -TestFile (Join-Path $Script:Config.GitDir 'cmd\git.exe') `
        -Label 'MinGit' | Out-Null

    # ── 3.4 GitLab Runner binary ─────────────────────────────
    Write-Log '3.4 GitLab Runner binary'
    if (-not (Install-S3Binary -S3Key $Script:Config.S3Keys.RunnerBin -DestPath $Script:Config.RunnerBin -Label 'GitLab Runner')) {
        Write-LogError 'FATAL: Runner binary download failed'; exit 1
    }

    # ── 3.5 Pre-pull Harbor images ───────────────────────────
    Write-Log '3.5 Pre-pull container images'
    if ($Script:Config.HarborUser -and $Script:Config.HarborPass) {
        Write-Log 'Logging into Harbor...'
        $Script:Config.HarborPass | docker login $Script:Config.HarborUrl -u $Script:Config.HarborUser --password-stdin 2>&1 |
            ForEach-Object { Write-Log "  docker login: $_" }
    }
    foreach ($image in $Script:Config.PrePullImages) {
        Write-Log "Pulling: $image"
        docker pull $image 2>&1 | ForEach-Object { Write-Log "  $_" }
        if ($LASTEXITCODE -ne 0) { Write-LogWarn "Failed to pull $image — will pull on first job" }
    }

    # ── 3.6 Write config.toml ────────────────────────────────
    Write-Log '3.6 Resolve runner token + write config.toml'

    # Token resolution: env var → Machine env → FATAL
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
    $dnsServers = Get-DnsServer
    $dnsLine = ''
    if ($dnsServers.Count -ge 2) { $dnsLine = "    dns = [`"$($dnsServers[0])`", `"$($dnsServers[1])`"]" }
    elseif ($dnsServers.Count -eq 1) { $dnsLine = "    dns = [`"$($dnsServers[0])`"]" }

    $buildsVol = "$($Script:Config.BuildsDir -replace '\\','\\'):C:\\builds"
    $cacheVol  = "$($Script:Config.CacheDir  -replace '\\','\\'):C:\\cache"
    $defaultImage = "$($Script:Config.HarborUrl)/golden-image/servercore:ltsc2019"

    # ── 3.7 Register runner (if not already auth token) ──────
    if ($isAuthToken) {
        Write-Log '3.7 Skip registration — glrt- token is already authenticated'
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
            Write-Log 'Registration successful — extracting auth token from config.toml'
            # After registration, gitlab-runner writes the real auth token to config.toml
            # Extract it so our config.toml rewrite uses the correct token
            $regConfig = Get-Content $Script:Config.ConfigToml -Raw -ErrorAction SilentlyContinue
            if ($regConfig -match 'token\s*=\s*"(glrt-[^"]+)"') {
                $runnerToken = $Matches[1]
                Write-Log "Extracted auth token: glrt-***"
            } else {
                Write-LogWarn 'Could not extract auth token from registration output — using original token'
            }
        } else {
            Write-LogWarn 'Runner registration non-zero. Will write config.toml with provided token — runner may still work.'
        }
    }

    # Write (or overwrite) config.toml with our full config
    $configContent = @"
# GitLab Runner Configuration — Auto-generated
# Host: $hostname | Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

concurrent = $($Script:Config.ConcurrentJobs)
check_interval = $($Script:Config.CheckInterval)
shutdown_timeout = 300
log_level = "info"

[[runners]]
  name = "runner-$hostname"
  url = "$($Script:Config.GitLabUrl)"
  token = "$runnerToken"
  executor = "docker-windows"
  tls-verify = false
  environment = ["GIT_SSL_NO_VERIFY=true", "DOCKER_TLS_CERTDIR="]
  pre_build_script = "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\GitLab-Runner\\scripts\\Write-JobLog.ps1 -Action start"
  post_build_script = "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\GitLab-Runner\\scripts\\Write-JobLog.ps1 -Action end"

  [runners.docker]
    image = "$defaultImage"
    helper_image = "$($Script:Config.HelperImage)"
    isolation = "process"
    pull_policy = ["if-not-present"]
    tls_verify = false
    privileged = false
    shm_size = 268435456
    volumes = ["$buildsVol", "$cacheVol"]
$dnsLine
    allowed_images = []
    allowed_services = []
    wait_for_services_timeout = 30
    disable_cache = false

  [runners.cache]
    Type = ""
"@
    $configContent | Out-File -FilePath $Script:Config.ConfigToml -Encoding UTF8 -Force
    Write-Log 'config.toml written'

    # ── 3.8 Install runner service (idempotent) ──────────────
    Write-Log '3.8 Install runner service'
    & $Script:Config.RunnerBin stop 2>$null
    & $Script:Config.RunnerBin uninstall 2>$null
    Start-Sleep -Seconds 2
    & $Script:Config.RunnerBin install 2>&1 | ForEach-Object { Write-Log "  install: $_" }
    & $Script:Config.RunnerBin start  2>&1 | ForEach-Object { Write-Log "  start: $_" }

    if (Wait-ServiceRunning -Name 'gitlab-runner' -TimeoutSeconds 30 -PollSeconds 3) {
        Write-Log 'GitLab Runner service is RUNNING'
    } else {
        Write-LogError 'GitLab Runner service failed to start'
    }

    # ── 3.9 Deploy maintenance scripts ───────────────────────
    Write-Log '3.9 Deploy maintenance scripts'
    foreach ($s in @(
        @{ Key = $Script:Config.S3Keys.HealthCheck; File = 'health-check.ps1' },
        @{ Key = $Script:Config.S3Keys.DiskMonitor;  File = 'disk-monitor.ps1' },
        @{ Key = $Script:Config.S3Keys.DockerWdog;   File = 'docker-watchdog.ps1' },
        @{ Key = $Script:Config.S3Keys.KillStale;    File = 'kill-stale-containers.ps1' },
        @{ Key = $Script:Config.S3Keys.RegTasks;     File = 'Register-ScheduledTasks.ps1' }
    )) {
        Get-S3Object -Key $s.Key -OutFile (Join-Path $Script:Config.ScriptsDir $s.File) | Out-Null
    }

    # Deploy new feature scripts
    foreach ($s in @(
        @{ Key = $Script:Config.S3KeysExtra.ImportCerts;    File = 'Import-Certificates.ps1' },
        @{ Key = $Script:Config.S3KeysExtra.EnableRemotePS; File = 'Enable-RemotePowerShell.ps1' },
        @{ Key = $Script:Config.S3KeysExtra.NetMonitor;     File = 'Test-NetworkConnectivity.ps1' },
        @{ Key = $Script:Config.S3KeysExtra.JobLog;         File = 'Write-JobLog.ps1' },
        @{ Key = $Script:Config.S3KeysExtra.RdpAudit;       File = 'Export-RdpAuditLog.ps1' },
        @{ Key = $Script:Config.S3KeysExtra.LogCollector;   File = 'Export-RunnerLogs.ps1' },
        @{ Key = $Script:Config.S3KeysExtra.GoldenVersion;  File = 'Write-GoldenVersion.ps1' }
    )) {
        Get-S3Object -Key $s.Key -OutFile (Join-Path $Script:Config.ScriptsDir $s.File) | Out-Null
    }
    # Create log subdirectories
    foreach ($d in @($Script:Config.JobLogDir, $Script:Config.NetLogDir, $Script:Config.RdpLogDir)) {
        if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
    }

    # ── 3.10 Register scheduled tasks ────────────────────────
    Write-Log '3.10 Register scheduled tasks'
    $regScript = Join-Path $Script:Config.ScriptsDir 'Register-ScheduledTasks.ps1'
    if (Test-Path $regScript) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $regScript 2>&1 |
            ForEach-Object { Write-Log "  tasks: $_" }
    } else {
        Write-LogWarn 'Register-ScheduledTasks.ps1 not found — inline fallback'
        Register-InlineScheduledTask
    }

    # ── 3.11 Deploy tools ────────────────────────────────────
    Write-Log '3.11 Deploy tools'
    $winrarExe = Join-Path $Script:Config.ToolsDir 'winrar-x64-701.exe'
    if (Get-S3Object -Key $Script:Config.S3Keys.WinRarExe -OutFile $winrarExe) {
        Start-Process -FilePath $winrarExe -ArgumentList '/s' -Wait -NoNewWindow -ErrorAction SilentlyContinue
        Remove-Item $winrarExe -Force -ErrorAction SilentlyContinue
        Write-Log 'WinRAR installed'
    }

    if (Install-S3Archive -S3Key $Script:Config.S3Keys.NssmZip -DestDir $Script:Config.ToolsDir -TestFile '' -Label 'NSSM') {
        $nssmExe = Get-ChildItem -Path $Script:Config.ToolsDir -Recurse -Filter 'nssm.exe' |
                   Where-Object { $_.FullName -like '*win64*' } | Select-Object -First 1
        if ($nssmExe) { Copy-Item $nssmExe.FullName (Join-Path $Script:Config.ToolsDir 'nssm.exe') -Force }
    }

    foreach ($si in @(
        @{ Key = $Script:Config.S3Keys.ProcExp; File = 'procexp64.exe' },
        @{ Key = $Script:Config.S3Keys.ProcMon; File = 'Procmon64.exe' },
        @{ Key = $Script:Config.S3Keys.Handle;  File = 'handle64.exe' }
    )) { Get-S3Object -Key $si.Key -OutFile (Join-Path $Script:Config.SysInternalsDir $si.File) | Out-Null }

    Install-S3Archive -S3Key $Script:Config.S3Keys.PsToolsZip -DestDir $Script:Config.SysInternalsDir -TestFile '' -Label 'PSTools' | Out-Null

    # OpenCode — installer + config
    $openCodeExe = Join-Path $Script:Config.ToolsDir 'opencode-setup.exe'
    if (Get-S3Object -Key $Script:Config.S3KeysExtra.OpenCodeExe -OutFile $openCodeExe) {
        Write-Log 'OpenCode installer downloaded (manual install later)'
    }
    $openCodeConfig = Join-Path $env:USERPROFILE '.config\opencode.jsonc'
    $openCodeConfigDir = Split-Path $openCodeConfig -Parent
    if (-not (Test-Path $openCodeConfigDir)) { New-Item -Path $openCodeConfigDir -ItemType Directory -Force | Out-Null }
    Get-S3Object -Key $Script:Config.S3KeysExtra.OpenCodeConfig -OutFile $openCodeConfig | Out-Null

    Write-Log 'Tools deployed'

    # ── 3.12 Final validation ────────────────────────────────
    Write-Log '========== FINAL VALIDATION =========='
    Invoke-FinalValidation

    # ── 3.13 Write golden image version stamp ───────────────────
    Write-Log '3.13 Write golden image version stamp'
    $versionScript = Join-Path $Script:Config.ScriptsDir 'Write-GoldenVersion.ps1'
    if (Test-Path $versionScript) {
        & $versionScript -ImageVersion $Script:Config.GoldenImageVersion 2>&1 |
            ForEach-Object { Write-Log "  version: $_" }
    } else {
        Write-LogWarn 'Write-GoldenVersion.ps1 not found — skipping version stamp'
    }

    Write-Log '========== PHASE 3 COMPLETE — RUNNER IS OPERATIONAL =========='
}

# ============================================================
# INLINE SCHEDULED TASKS (fallback if Register-ScheduledTasks.ps1 missing)
# ============================================================

function Register-InlineScheduledTask {
    $sd = $Script:Config.ScriptsDir
    $pr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $forever = New-TimeSpan -Days 3650
    $tasks = @(
        @{ Name='Docker-Image-Prune';          Trigger=(New-ScheduledTaskTrigger -Daily -At '03:00');                                                                         Action="-NoProfile -Command `"docker image prune -a --filter 'until=168h' --force 2>&1 | Out-File C:\GitLab-Runner\logs\image-prune.log -Append`"" },
        @{ Name='Docker-Container-Cleanup';    Trigger=(New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Hours 4) -RepetitionDuration $forever);  Action="-NoProfile -Command `"docker container prune --force 2>&1 | Out-File C:\GitLab-Runner\logs\container-prune.log -Append`"" },
        @{ Name='Docker-Stale-Container-Kill'; Trigger=(New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Hours 2) -RepetitionDuration $forever);  Action="-NoProfile -ExecutionPolicy Bypass -File `"$sd\kill-stale-containers.ps1`"" },
        @{ Name='Docker-Volume-Prune';         Trigger=(New-ScheduledTaskTrigger -Daily -At '03:30');                                                                         Action="-NoProfile -Command `"docker volume prune --force 2>&1 | Out-File C:\GitLab-Runner\logs\volume-prune.log -Append`"" },
        @{ Name='Docker-BuildCache-Prune';     Trigger=(New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '04:00');                                                      Action="-NoProfile -Command `"docker builder prune --all --force 2>&1 | Out-File C:\GitLab-Runner\logs\buildcache-prune.log -Append`"" },
        @{ Name='Runner-Workspace-Cleanup';    Trigger=(New-ScheduledTaskTrigger -Daily -At '04:00');                                                                         Action="-NoProfile -Command `"Get-ChildItem '$($Script:Config.BuildsDir)' -Directory | Where-Object { `$_.LastWriteTime -lt (Get-Date).AddDays(-3) } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue`"" },
        @{ Name='Disk-Space-Monitor';          Trigger=(New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration $forever);Action="-NoProfile -ExecutionPolicy Bypass -File `"$sd\disk-monitor.ps1`"" },
        @{ Name='Docker-Daemon-Watchdog';      Trigger=(New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration $forever); Action="-NoProfile -ExecutionPolicy Bypass -File `"$sd\docker-watchdog.ps1`"" },
        @{ Name='Runner-Service-Watchdog';     Trigger=(New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration $forever); Action="-NoProfile -Command `"if ((Get-Service gitlab-runner -ErrorAction SilentlyContinue).Status -ne 'Running') { Start-Service gitlab-runner; Write-EventLog -LogName Application -Source 'GitLabRunner' -EventId 9004 -EntryType Warning -Message 'Runner restarted.' }`"" },
        @{ Name='Log-Rotation';                Trigger=(New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '05:00');                                                      Action="-NoProfile -Command `"Get-ChildItem 'C:\GitLab-Runner\logs\*.log' | Where-Object { `$_.Length -gt 50MB } | ForEach-Object { Move-Item `$_.FullName (`$_.FullName + '.old') -Force }`"" },
        @{ Name='Network-Connectivity-Monitor';Trigger=(New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration $forever);  Action="-NoProfile -ExecutionPolicy Bypass -File `"$sd\Test-NetworkConnectivity.ps1`"" },
        @{ Name='RDP-Audit-Logger';            Trigger=(New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration $forever);  Action="-NoProfile -ExecutionPolicy Bypass -File `"$sd\Export-RdpAuditLog.ps1`"" }
    )
    foreach ($t in $tasks) {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $t.Action
        Register-ScheduledTask -TaskName $t.Name -Action $action -Trigger $t.Trigger -Principal $pr -Force | Out-Null
    }
    Write-Log "Registered $($tasks.Count) scheduled tasks (inline fallback)"
}
