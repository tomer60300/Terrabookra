#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Be1 Post-Install Orchestrator — GitLab Runner Golden Image (Docker Executor, Windows)

.DESCRIPTION
    Executed by VMware Aria (Be1) on a freshly provisioned Windows Server 2019 VM.
    Produces a fully operational GitLab Runner registered at Group level.

    This script is the ORCHESTRATOR — it loads configuration and helpers, then
    dispatches to the correct phase based on marker files:

      No markers         → Phase 1 (phases/Phase1-SystemPrep.ps1)
      .phase1_complete   → Phase 2 (phases/Phase2-DockerInstall.ps1)
      .phase2_complete   → Phase 3 (phases/Phase3-RunnerSetup.ps1)

    Three-phase execution with two reboots:
      Phase 1: System prep, services, env vars, dirs, Windows features → REBOOT
      Phase 2: daemon.json, Docker binaries, dockerd service → REBOOT
      Phase 3: Docker verify, runner install, registration, maintenance, validation

    All binaries from MinIO bucket "gitlab-runner-golden" via AWS Sig V4.
    All container images from Harbor project "golden-image".

.NOTES
    Target OS:       Windows Server 2019 LTSC (Build 17763)
    GitLab:          16.7.10-ee (self-managed, self-signed cert)
    Runner:          16.7.0
    Docker:          25.0.15 (raw docker.exe + dockerd.exe)
    Executor:        docker-windows (process isolation)

    Disk layout expected:
      C: (100 GB) — OS, runner binary, tools
      E: (1 TB)   — Docker data-root, pagefile, builds, cache

    Module layout:
      lib/Config.ps1                    — All settings, paths, constants
      lib/Common.ps1                    — TLS, logging, S3, PE, phase markers, reboot
      phases/Phase1-SystemPrep.ps1      — System preparation
      phases/Phase2-DockerInstall.ps1   — Docker installation
      phases/Phase3-RunnerSetup.ps1     — Runner setup, maintenance, tools
      validation/Invoke-FinalValidation.ps1 — 17-check validation suite
#>

# ============================================================
# RESOLVE SCRIPT ROOT (works on Be1 re-runs and direct invocation)
# ============================================================

$Script:ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# ============================================================
# LOAD MODULES
# ============================================================

. (Join-Path $Script:ScriptRoot 'lib\Config.ps1')
. (Join-Path $Script:ScriptRoot 'lib\Common.ps1')
. (Join-Path $Script:ScriptRoot 'phases\Phase1-SystemPrep.ps1')
. (Join-Path $Script:ScriptRoot 'phases\Phase2-DockerInstall.ps1')
. (Join-Path $Script:ScriptRoot 'phases\Phase3-RunnerSetup.ps1')
. (Join-Path $Script:ScriptRoot 'validation\Invoke-FinalValidation.ps1')

# ============================================================
# MAIN — Phase Detection & Dispatch
# ============================================================

try {
    Write-Log '============================================'
    Write-Log "Install-GitLabRunner.ps1 — START (orchestrator)"
    Write-Log "Host: $env:COMPUTERNAME | OS: $([System.Environment]::OSVersion.VersionString)"
    Write-Log "Data drive: $Script:DataDrive"
    Write-Log "Script root: $Script:ScriptRoot"
    Write-Log '============================================'

    if (Test-PhaseComplete $Script:Config.Phase2Marker) {
        Write-Log 'Phase 2 marker found → dispatching Phase 3'
        Invoke-Phase3
    }
    elseif (Test-PhaseComplete $Script:Config.Phase1Marker) {
        Write-Log 'Phase 1 marker found → dispatching Phase 2'
        Invoke-Phase2
    }
    else {
        Write-Log 'No markers found → dispatching Phase 1'
        Invoke-Phase1
    }
}
catch {
    Write-LogError "UNHANDLED EXCEPTION: $($_.Exception.Message)"
    Write-LogError "Stack trace: $($_.ScriptStackTrace)"
    exit 1
}
