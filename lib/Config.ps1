<#
.SYNOPSIS
    Configuration -- all settings, paths, and constants for the GitLab Runner golden image.

.DESCRIPTION
    Dot-sourced by Install-GitLabRunner.ps1 before anything else runs.
    Defines $Script:Config (hashtable) and resolves the data drive (E: preferred, C: fallback).

    Edit the values below to match your environment. Credentials are placeholders --
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
# BASE URLs -- Single source of truth for all hostnames/servers.
# Edit ONLY these variables; everything else derives from them.
# ============================================================

$_harborHost       = 'harbor.kayhut.com'
$_harborProject    = 'golden-image'
$_gitLabHost       = 'gitlab.kayhut.com'
$_gitLabRegistry   = "${_gitLabHost}:5050"
$_minioHost        = 'kayhut-minio.com'
$_minioPort        = 9000
$_artifactoryHost  = 'artifactory-prod'
$_be1Host          = 'be1.kayhut.com'

# ============================================================
# CONFIGURATION
# ============================================================

$Script:Config = @{

    # --- MinIO S3 ---
    MinioEndpoint    = "https://${_minioHost}:${_minioPort}"
    MinioBucket      = 'gitlab-runner-golden'
    MinioAccessKey   = 'YOUR_ACCESS_KEY_HERE'
    MinioSecretKey   = 'YOUR_SECRET_KEY_HERE'
    MinioRegion      = 'us-east-1'

    # --- GitLab ---
    # GITLAB_RUNNER_TOKEN must be set as env var or Machine-level variable
    # before running. Two formats supported:
    #   glrt-XXXX  = Runner Authentication Token (GitLab 16.0+)
    #                Created via GitLab UI: Settings > CI/CD > Runners > New runner
    #                Goes directly into config.toml, no registration needed.
    #   PAT / legacy registration token
    #                Script will call `gitlab-runner register --registration-token`
    #                and extract the resulting auth token.
    GitLabUrl        = "https://${_gitLabHost}"

    # --- Harbor ---
    HarborUrl        = $_harborHost
    HarborProject    = $_harborProject
    HarborUser       = ''
    HarborPass       = ''

    # --- Hosts (for InsecureRegistries + MonitorHosts) ---
    GitLabRegistry   = $_gitLabRegistry
    ArtifactoryHost  = $_artifactoryHost
    Be1Host          = $_be1Host

    # --- Paths (C: drive -- OS, binaries, tools) ---
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

    # --- Paths (E: drive preferred -- resolved from $DataDrive) ---
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

    # --- Certificates ---
    CertsDir         = 'C:\GitLab-Runner\certs'

    # --- Job logging ---
    JobLogDir        = 'C:\GitLab-Runner\logs\jobs'
    JobLogMaxDays    = 30

    # --- Network monitor ---
    NetLogDir        = 'C:\GitLab-Runner\logs\network'
    NetLogMaxDays    = 30

    # --- RDP audit ---
    RdpLogDir        = 'C:\GitLab-Runner\logs\rdp'
    RdpLogMaxDays    = 30

    # --- Certificate S3 keys ---
    S3Certs = @(
        'certs/kayhut-ca.crt'
    )

    # --- MinIO object keys (new scripts) ---
    S3KeysExtra = @{
        ImportCerts    = 'scripts/Import-Certificates.ps1'
        EnableRemotePS = 'scripts/Enable-RemotePowerShell.ps1'
        NetMonitor     = 'scripts/Test-NetworkConnectivity.ps1'
        JobLog         = 'scripts/Write-JobLog.ps1'
        RdpAudit       = 'scripts/Export-RdpAuditLog.ps1'
        LogCollector   = 'scripts/Export-RunnerLogs.ps1'
        GoldenVersion  = 'scripts/Write-GoldenVersion.ps1'
        OpenCodeExe    = 'tools/opencode/opencode-desktop-windows-x64-setup.exe'
        OpenCodeConfig = 'tools/opencode/opencode.jsonc'
        DepValidator   = 'validation/Test-Dependencies.ps1'
    }

    # --- Golden image version ---
    GoldenImageVersion = '2.3.1'

    # --- Services to disable ---
    DisableServices = @(
        'WSearch', 'Spooler', 'Fax', 'WerSvc', 'DiagTrack', 'SysMain',
        'wuauserv', 'BITS', 'RemoteRegistry', 'MapsBroker', 'lfsvc',
        'RetailDemo', 'WMPNetworkSvc', 'XblAuthManager', 'XblGameSave',
        'XboxNetApiSvc', 'TabletInputService'
    )
}

# ============================================================
# DERIVED VALUES -- Built from base URLs (do NOT hardcode hosts below)
# ============================================================

$Script:Config.PrePullImages = @(
    "${_harborHost}/${_harborProject}/gitlab-runner-helper:x86_64-v16.7.0-servercore1809",
    "${_harborHost}/${_harborProject}/servercore:ltsc2019",
    "${_harborHost}/${_harborProject}/windows:ltsc2019"
)

$Script:Config.HelperImage = "${_harborHost}/${_harborProject}/gitlab-runner-helper:x86_64-v16.7.0-servercore1809"

$Script:Config.InsecureRegistries = @(
    $_harborHost,
    $_gitLabRegistry,
    $_artifactoryHost
)

$Script:Config.MonitorHosts = @(
    @{ Host = $_gitLabHost;       Port = 443          },
    @{ Host = $_harborHost;       Port = 443          },
    @{ Host = $_minioHost;        Port = $_minioPort   },
    @{ Host = $_artifactoryHost;  Port = 443          },
    @{ Host = $_be1Host;          Port = 443          }
)
