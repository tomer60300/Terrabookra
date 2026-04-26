<#
.SYNOPSIS
    Phase 2 -- Docker daemon.json + binary install + service registration.

.DESCRIPTION
    Called after Phase 1 marker is detected.
    Installs Docker from raw binaries (not Mirantis):

    2.1  Write daemon.json (insecure registries, logging, data-root)
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
  "group": "docker-users"
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

    # -- 2.2 Download Docker binaries -------------------------
    Write-Log '2.2 Download Docker binaries'
    $dockerExe  = Join-Path $Script:Config.DockerDir 'docker.exe'
    $dockerdExe = Join-Path $Script:Config.DockerDir 'dockerd.exe'

    if (-not (Install-S3Binary -S3Key $Script:Config.S3Keys.DockerExe  -DestPath $dockerExe  -Label 'docker.exe'))  {
        Write-LogError 'FATAL: docker.exe download failed'; exit 1
    }
    if (-not (Install-S3Binary -S3Key $Script:Config.S3Keys.DockerdExe -DestPath $dockerdExe -Label 'dockerd.exe')) {
        Write-LogError 'FATAL: dockerd.exe download failed'; exit 1
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
            & $dockerdExe --unregister-service 2>&1 | ForEach-Object { Write-Log "  unregister: $_" }
            Start-Sleep -Seconds 3
        }

        & $dockerdExe --register-service 2>&1 | ForEach-Object { Write-Log "  register: $_" }
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

    # -- Mark + dispatch --------------------------------------
    Set-PhaseMarker $Script:Config.Phase2Marker
    Write-Log '========== PHASE 2 COMPLETE =========='

    $dockerSvc = Get-Service docker -ErrorAction SilentlyContinue
    if (-not $dockerSvc -or $dockerSvc.Status -ne 'Running') {
        Invoke-Be1Reboot -Reason 'Phase 2 complete -- Docker installed, reboot required'
    } else {
        Write-Log 'Docker running, continuing to Phase 3...'
        Invoke-Phase3
    }
}
