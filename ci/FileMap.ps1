<#
.SYNOPSIS
    Shared $FileMap -- single source of truth for what gets synced to MinIO.

.DESCRIPTION
    Hashtable of {repo-relative-path -> S3-object-key}. Dot-sourced by both:
      - ci/Sync-ToMinio.ps1     -- uploads each entry via AWS SigV4 PUT
      - validation/Test-Dependencies.ps1
                                 -- HEAD-checks each S3 key + verifies MD5
                                    matches the local repo file (ETag-based
                                    content-match check, single-PUT only)

    Adding a new file to the bootstrap chain means adding ONE row here. Both
    upload and verification then pick it up automatically.

.NOTES
    File: ci/FileMap.ps1
    Sets: $Script:FileMap [ordered]
#>

$Script:FileMap = [ordered]@{
    # --- Bootstrap entry point (Be1 fetches this) ---
    'Bootstrap-GitLabRunner.ps1'               = 'Bootstrap-GitLabRunner.ps1'

    # --- lib (Phase 0 downloads these) ---
    'lib/Config.ps1'                           = 'bootstrap/lib/Config.ps1'
    'lib/Common.ps1'                           = 'bootstrap/lib/Common.ps1'

    # --- phases (Phase 0 downloads these) ---
    'phases/Phase1-SystemPrep.ps1'             = 'bootstrap/phases/Phase1-SystemPrep.ps1'
    'phases/Phase2-DockerInstall.ps1'          = 'bootstrap/phases/Phase2-DockerInstall.ps1'
    'phases/Phase3-RunnerSetup.ps1'            = 'bootstrap/phases/Phase3-RunnerSetup.ps1'

    # --- validation ---
    'validation/Invoke-FinalValidation.ps1'    = 'bootstrap/validation/Invoke-FinalValidation.ps1'
    'validation/Test-Dependencies.ps1'         = 'validation/Test-Dependencies.ps1'

    # --- scripts (Phase 3 downloads these) ---
    'scripts/health-check.ps1'                 = 'scripts/health-check.ps1'
    'scripts/disk-monitor.ps1'                 = 'scripts/disk-monitor.ps1'
    'scripts/docker-watchdog.ps1'              = 'scripts/docker-watchdog.ps1'
    'scripts/kill-stale-containers.ps1'        = 'scripts/kill-stale-containers.ps1'
    'scripts/Register-ScheduledTasks.ps1'      = 'scripts/Register-ScheduledTasks.ps1'
    'scripts/Import-Certificates.ps1'          = 'scripts/Import-Certificates.ps1'
    'scripts/Enable-RemoteSSH.ps1'             = 'scripts/Enable-RemoteSSH.ps1'
    'scripts/Test-NetworkConnectivity.ps1'     = 'scripts/Test-NetworkConnectivity.ps1'
    'scripts/Write-JobLog.ps1'                 = 'scripts/Write-JobLog.ps1'
    'scripts/Export-RdpAuditLog.ps1'           = 'scripts/Export-RdpAuditLog.ps1'
    'scripts/Export-RunnerLogs.ps1'            = 'scripts/Export-RunnerLogs.ps1'
    'scripts/Write-GoldenVersion.ps1'          = 'scripts/Write-GoldenVersion.ps1'
    'scripts/Install-Tools.ps1'                = 'scripts/Install-Tools.ps1'
    'scripts/Install-OpenCode.ps1'             = 'scripts/Install-OpenCode.ps1'
    'scripts/Install-Observability.ps1'        = 'scripts/Install-Observability.ps1'
    'scripts/Assert-Environment.ps1'           = 'scripts/Assert-Environment.ps1'
    'scripts/Set-WindowsTerminalDefault.ps1'   = 'scripts/Set-WindowsTerminalDefault.ps1'

    # --- tools (config files only -- binaries are uploaded out-of-band via USB) ---
    'tools/opencode/opencode.jsonc'            = 'tools/opencode/opencode.jsonc'
}
