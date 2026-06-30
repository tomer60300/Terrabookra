<#
.SYNOPSIS
    Phase 2 -- Docker daemon.json + binary install + service registration.

.DESCRIPTION
    Called after Phase 1 marker is detected.
    Installs Docker from raw binaries (not Mirantis):

    2.1  Write daemon.json (insecure registries, logging, data-root,
         and Prometheus metrics endpoint on TCP 9323)
    2.2  Download docker.exe + dockerd.exe from MinIO
    2.3  Register dockerd as Windows service

    Reboots via Be1 if Docker service isn't running yet, otherwise continues to Phase 3.

.NOTES
    File: phases/Phase2-DockerInstall.ps1
    Requires: lib/Config.ps1, lib/Common.ps1 (dot-sourced by orchestrator)
#>

function Invoke-Phase2 {
    Write-Log '========== PHASE 2: Docker Installation =========='

    # -- 2.1 Write daemon.json --------------------------------
    Write-Log '2.1 Write daemon.json'

    # Ensure docker-users group exists (raw binary install does not create it)
    if (-not (Get-LocalGroup -Name 'docker-users' -ErrorAction SilentlyContinue)) {
        New-LocalGroup -Name 'docker-users' -Description 'Docker daemon pipe access'
        Write-Log 'Created local group: docker-users'
    }

    $registries = ($Script:Config.InsecureRegistries | ForEach-Object { "    `"$_`"" }) -join ",`n"
    $dataRoot   = $Script:Config.DockerDataRoot -replace '\\', '\\'

    # NOTE: dns and exec-opts deliberately omitted:
    #   dns            -- process isolation inherits host DNS (domain-joined via Be1)
    #   exec-opts      -- isolation=process is the default on Windows Server 2019
    #   storage-driver -- windowsfilter is the implicit default on Windows (Docker 25.x rejects it)
    #
    # metrics-addr + experimental:true expose the Docker daemon's Prometheus
    # endpoint on TCP 9323. The endpoint requires experimental mode in Docker
    # 25.x; it's safe to enable for metrics alone (no other experimental
    # features get picked up). Firewall hole opened by Install-Observability.ps1.
    $dockerMetricsPort = $Script:Config.MetricsPorts.Docker

    $daemonJson = @"
{
  "insecure-registries": [
$registries
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  },
  "max-concurrent-downloads": 5,
  "max-concurrent-uploads": 3,
  "max-download-attempts": 5,
  "debug": false,
  "data-root": "$dataRoot",
  "group": "docker-users",
  "metrics-addr": "0.0.0.0:$dockerMetricsPort",
  "experimental": true
}
"@

    $daemonJson | Out-File -FilePath $Script:Config.DaemonJson -Encoding UTF8 -Force
    Write-Log "daemon.json written (data-root: $($Script:Config.DockerDataRoot))"

    # Ensure data-root exists and is on NTFS before dockerd starts
    if (-not (Test-Path $Script:Config.DockerDataRoot)) {
        New-Item -Path $Script:Config.DockerDataRoot -ItemType Directory -Force | Out-Null
    }
    $drLetter = ($Script:Config.DockerDataRoot).Substring(0, 1)
    $drInfo   = Get-Volume -DriveLetter $drLetter -ErrorAction SilentlyContinue
    if ($drInfo) {
        if ($drInfo.FileSystemType -ne 'NTFS') {
            Write-LogError "FATAL: data-root drive ${drLetter}: is $($drInfo.FileSystemType) -- must be NTFS"
            exit 1
        }
        $freeGB = [math]::Round($drInfo.SizeRemaining / 1GB, 1)
        Write-Log "data-root drive ${drLetter}: filesystem=NTFS free=${freeGB}GB"
    } else {
        Write-LogWarn "Could not verify drive ${drLetter}: -- ensure it is NTFS"
    }

    # -- 2.2 Install Docker binaries (from the uploaded repo) -
    Write-Log '2.2 Install Docker binaries'
    $dockerExe  = Join-Path $Script:Config.DockerDir 'docker.exe'
    $dockerdExe = Join-Path $Script:Config.DockerDir 'dockerd.exe'

    if (-not (Install-LocalBinary -RelPath $Script:Config.S3Keys.DockerExe  -DestPath $dockerExe  -Label 'docker.exe'))  {
        Write-LogError 'FATAL: docker.exe install failed'; exit 1
    }
    if (-not (Install-LocalBinary -RelPath $Script:Config.S3Keys.DockerdExe -DestPath $dockerdExe -Label 'dockerd.exe')) {
        Write-LogError 'FATAL: dockerd.exe install failed'; exit 1
    }

    # -- 2.3 Register dockerd as Windows service --------------
    Write-Log '2.3 Register Docker service'
    $dockerSvc = Get-Service docker -ErrorAction SilentlyContinue

    if ($dockerSvc -and $dockerSvc.Status -eq 'Running') {
        Write-Log 'Docker service already running'
    } else {
        if ($dockerSvc) {
            Write-Log 'Removing stale Docker service...'
            Stop-Service docker -Force -ErrorAction SilentlyContinue
            & { $ErrorActionPreference = 'Continue'; & $dockerdExe --unregister-service 2>&1 } | ForEach-Object { Write-Log "  unregister: $_" }
            Start-Sleep -Seconds 3
        }

        & { $ErrorActionPreference = 'Continue'; & $dockerdExe --register-service 2>&1 } | ForEach-Object { Write-Log "  register: $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-LogError 'FATAL: dockerd --register-service failed'
            exit 1
        }
        Write-Log 'dockerd registered as Windows service'

        Start-Service docker -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 10

        # Verify service didn't crash (Error 1067 = daemon.json invalid or driver failure)
        $dockerSvc = Get-Service docker -ErrorAction SilentlyContinue
        if ($dockerSvc -and $dockerSvc.Status -eq 'Stopped') {
            Write-LogError 'Docker service started but crashed (Error 1067).'
            Write-LogError 'Check daemon.json for invalid options or data-root drive issues.'
            Write-LogError "daemon.json: $($Script:Config.DaemonJson)"
            Write-LogError "data-root:   $($Script:Config.DockerDataRoot)"
            # Dump daemon.json to log for remote debugging
            $djContent = Get-Content $Script:Config.DaemonJson -Raw -ErrorAction SilentlyContinue
            Write-LogError "daemon.json content:`n$djContent"
            exit 1
        }
    }

    # -- Mark + complete --------------------------------------
    Set-PhaseMarker $Script:Config.Phase2Marker
    Write-Log '========== PHASE 2 COMPLETE =========='

    # Packer owns sequencing: it issues a `windows-restart` after this phase and
    # then runs Invoke-Phase 3 (Phase3-Install). No self-reboot, no self-chain.
    $dockerSvc = Get-Service docker -ErrorAction SilentlyContinue
    if (-not $dockerSvc -or $dockerSvc.Status -ne 'Running') {
        Write-Log 'Docker not yet running -- Packer windows-restart will follow before Phase 3.'
    } else {
        Write-Log 'Docker running -- Packer will restart before Phase 3.'
    }
}
