<#
.SYNOPSIS
    Configuration — all settings, paths, and constants for the GitLab Runner golden image.

.DESCRIPTION
    Dot-sourced by Install-GitLabRunner.ps1 before anything else runs.
    Defines $Script:Config (hashtable) and resolves the data drive (E: preferred, C: fallback).

    Edit the values below to match your environment. Credentials are placeholders —
    replace before uploading to MinIO.

.NOTES
    File: lib/Config.ps1
    Used by: Install-GitLabRunner.ps1 (orchestrator)
#>

# ============================================================
# DATA DRIVE (E: preferred, C: fallback)
# ============================================================

$Script:DataDrive = if (Test-Path 'E:\') { 'E:' } else { 'C:' }

# ============================================================
# CONFIGURATION
# ============================================================

$Script:Config = @{

    # --- MinIO S3 ---
    MinioEndpoint    = 'https://kayhut-minio.com:9000'
    MinioBucket      = 'gitlab-runner-golden'
    MinioAccessKey   = 'YOUR_ACCESS_KEY_HERE'
    MinioSecretKey   = 'YOUR_SECRET_KEY_HERE'
    MinioRegion      = 'us-east-1'

    # --- GitLab ---
    GitLabUrl        = 'https://gitlab.kayhut.com'

    # --- Harbor ---
    HarborUrl        = 'harbor.kayhut.com'
    HarborUser       = ''
    HarborPass       = ''

    # --- Paths (C: drive — OS, binaries, tools) ---
    RunnerDir        = 'C:\GitLab-Runner'
    RunnerBin        = 'C:\GitLab-Runner\gitlab-runner.exe'
    ConfigToml       = 'C:\GitLab-Runner\config.toml'
    LogsDir          = 'C:\GitLab-Runner\logs'
    ScriptsDir       = 'C:\GitLab-Runner\scripts'
    GitDir           = 'C:\GitLab-Runner\git'
    ToolsDir         = 'C:\Tools'
    SysInternalsDir  = 'C:\Tools\SysInternals'
    DockerConfigDir  = 'C:\ProgramData\docker\config'
    DaemonJson       = 'C:\ProgramData\docker\config\daemon.json'
    DockerDir        = 'C:\Program Files\Docker'

    # --- Paths (E: drive preferred — resolved from $DataDrive) ---
    BuildsDir        = "$Script:DataDrive\GitLab-Runner\builds"
    CacheDir         = "$Script:DataDrive\GitLab-Runner\cache"
    DockerDataRoot   = "$Script:DataDrive\docker-data"

    # --- Phase Markers ---
    Phase1Marker     = 'C:\GitLab-Runner\.phase1_complete'
    Phase2Marker     = 'C:\GitLab-Runner\.phase2_complete'

    # --- Thresholds ---
    StaleMinutes     = 60
    PagefileMaxMB    = 32768

    # --- Runner defaults ---
    ConcurrentJobs   = 2
    CheckInterval    = 3

    # --- MinIO object keys ---
    S3Keys = @{
        RunnerBin    = 'binaries/gitlab-runner-16.7.0-windows-amd64.exe'
        DockerExe    = 'binaries/docker/docker.exe'
        DockerdExe   = 'binaries/docker/dockerd.exe'
        MinGitZip    = 'binaries/git/MinGit-2.43.0-64-bit.zip'
        WinRarExe    = 'tools/winrar-x64-701.exe'
        NssmZip      = 'tools/nssm-2.24.zip'
        ProcExp      = 'tools/sysinternals/procexp64.exe'
        ProcMon      = 'tools/sysinternals/Procmon64.exe'
        Handle       = 'tools/sysinternals/handle64.exe'
        PsToolsZip   = 'tools/sysinternals/PSTools.zip'
        HealthCheck  = 'scripts/health-check.ps1'
        DiskMonitor  = 'scripts/disk-monitor.ps1'
        DockerWdog   = 'scripts/docker-watchdog.ps1'
        KillStale    = 'scripts/kill-stale-containers.ps1'
        RegTasks     = 'scripts/Register-ScheduledTasks.ps1'
    }

    # --- Pre-pull images ---
    PrePullImages = @(
        'harbor.kayhut.com/golden-image/gitlab-runner-helper:x86_64-v16.7.0-servercore1809',
        'harbor.kayhut.com/golden-image/servercore:ltsc2019',
        'harbor.kayhut.com/golden-image/windows:ltsc2019'
    )

    HelperImage = 'harbor.kayhut.com/golden-image/gitlab-runner-helper:x86_64-v16.7.0-servercore1809'

    InsecureRegistries = @(
        'harbor.kayhut.com',
        'gitlab.kayhut.com:5050',
        'artifactory-prod'
    )

    # --- Certificates ---
    CertsDir         = 'C:\GitLab-Runner\certs'

    # --- Job logging ---
    JobLogDir        = 'C:\GitLab-Runner\logs\jobs'
    JobLogMaxDays    = 30

    # --- Network monitor ---
    NetLogDir        = 'C:\GitLab-Runner\logs\network'
    NetLogMaxDays    = 30
    MonitorHosts     = @(
        @{ Host = 'gitlab.kayhut.com';  Port = 443  },
        @{ Host = 'harbor.kayhut.com';  Port = 443  },
        @{ Host = 'kayhut-minio.com';   Port = 9000 },
        @{ Host = 'artifactory-prod';   Port = 443  },
        @{ Host = 'be1.kayhut.com';     Port = 443  }
    )

    # --- RDP audit ---
    RdpLogDir        = 'C:\GitLab-Runner\logs\rdp'
    RdpLogMaxDays    = 30

    # --- MinIO object keys (new scripts) ---
    S3KeysExtra = @{
        ImportCerts    = 'scripts/Import-Certificates.ps1'
        EnableRemotePS = 'scripts/Enable-RemotePowerShell.ps1'
        NetMonitor     = 'scripts/Test-NetworkConnectivity.ps1'
        JobLog         = 'scripts/Write-JobLog.ps1'
        RdpAudit       = 'scripts/Export-RdpAuditLog.ps1'
        OpenCodeExe    = 'tools/opencode/opencode-desktop-windows-x64-setup.exe'
        OpenCodeConfig = 'tools/opencode/opencode.jsonc'
    }

    # --- Services to disable ---
    DisableServices = @(
        'WSearch', 'Spooler', 'Fax', 'WerSvc', 'DiagTrack', 'SysMain',
        'wuauserv', 'BITS', 'RemoteRegistry', 'MapsBroker', 'lfsvc',
        'RetailDemo', 'WMPNetworkSvc', 'XblAuthManager', 'XblGameSave',
        'XboxNetApiSvc', 'TabletInputService'
    )
}
