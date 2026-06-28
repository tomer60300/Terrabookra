<#
.SYNOPSIS
    Configuration -- all settings, paths, and constants for the GitLab Runner golden image.

.DESCRIPTION
    Dot-sourced by Bootstrap-GitLabRunner.ps1 after Phase 0 downloads it from MinIO.
    Defines $Script:Config (hashtable) and resolves the data drive (E: preferred, C: fallback).

    Edit the values below to match your environment. Credentials are placeholders --
    replace before uploading to MinIO.

.NOTES
    File: lib/Config.ps1
    Used by: Bootstrap-GitLabRunner.ps1 (orchestrator)
#>

# ============================================================
# DATA DRIVE (E: preferred, C: fallback)
# ============================================================

$Script:DataDrive = if (Test-Path 'E:\') { 'E:' } else { 'C:' }

# ============================================================
# BASE URLs -- Single source of truth for all hostnames/servers.
# Edit ONLY these variables; everything else derives from them.
#
# Decision (3) -- aliases by name resolution, NOT byte substitution:
# each host reads its $env:REAL_* override and falls back to the public
# *.kayhut.com alias. The alias STAYS in source on both legs; the internal
# leg resolves it by hosts/DNS or overrides it via env. There is no
# Substitute-Aliases publish step anymore.
#
# Harbor is RETIRED. Container images (base/helper/app) now come from the
# GitLab Container Registry ($_gitLabRegistry). $_registryProject is the
# registry namespace that holds the mirrored golden-image content.
# ============================================================

$_gitLabHost       = if ($env:REAL_GITLAB_HOST)     { $env:REAL_GITLAB_HOST }     else { 'gitlab.kayhut.com' }
$_gitLabRegistry   = if ($env:REAL_GITLAB_REGISTRY) { $env:REAL_GITLAB_REGISTRY } else { "${_gitLabHost}:5050" }
$_registryProject  = if ($env:REAL_REGISTRY_PROJECT){ $env:REAL_REGISTRY_PROJECT }else { 'golden-image' }
$_minioHost        = if ($env:REAL_MINIO_HOST)      { $env:REAL_MINIO_HOST }      else { 'kayhut-minio.com' }
$_minioPort        = if ($env:REAL_MINIO_PORT)      { [int]$env:REAL_MINIO_PORT } else { 9000 }
$_artifactoryHost  = if ($env:REAL_ARTIFACTORY_HOST){ $env:REAL_ARTIFACTORY_HOST }else { 'artifactory-prod' }
$_be1Host          = if ($env:REAL_BE1_HOST)        { $env:REAL_BE1_HOST }        else { 'be1.kayhut.com' }

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

    # --- Container image registry (GitLab Container Registry; Harbor retired) ---
    # Base/helper/app images are pulled from here at build time and baked into
    # the golden image. Login uses GitLabRegistryUser/Pass below.
    RegistryHost     = $_gitLabRegistry
    RegistryProject  = $_registryProject

    # --- Hosts (for InsecureRegistries + MonitorHosts) ---
    GitLabRegistry   = $_gitLabRegistry
    ArtifactoryHost  = $_artifactoryHost

    # --- GitLab Container Registry login (Phase 3 step 3.5; pull+push) ---
    # Project/Group Access Token: User = token name, Pass = token value.
    # Role Developer+ with scopes read_registry + write_registry.
    # Placeholders here -- fill the real values on the internal/deploy copy only.
    # Login is non-fatal: a failure is logged verbosely and provisioning continues.
    # Injected at build time via env (Packer provisioner environment_vars) so the
    # registry password is never baked into the image (migration doc 5.3).
    GitLabRegistryUser = if ($env:REAL_GITLAB_REGISTRY_USER) { $env:REAL_GITLAB_REGISTRY_USER } else { '' }
    GitLabRegistryPass = if ($env:REAL_GITLAB_REGISTRY_PASS) { $env:REAL_GITLAB_REGISTRY_PASS } else { '' }

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

    # --- OpenCode (machine-wide config + staging) ---
    OpenCodeStageDir       = 'C:\Tools\opencode'
    OpenCodeInstallerLocal = 'C:\Tools\opencode\opencode-desktop-windows-x64-setup.exe'
    OpenCodeJsoncSource    = 'C:\Tools\opencode\opencode.jsonc'
    OpenCodeMachineDir     = 'C:\ProgramData\opencode'
    OpenCodeMachineFile    = 'C:\ProgramData\opencode\opencode.jsonc'

    # --- WebView2 (OpenCode prerequisite) ---
    WebView2StageDir       = 'C:\Tools\WebView2'
    WebView2InstallerLocal = 'C:\Tools\WebView2\MicrosoftEdgeWebView2RuntimeInstallerX64.exe'

    # --- OpenSSH (replaces WinRM for remote control -- WinRM blocked by GPO) ---
    # Auth model on a domain-joined runner: AD password auth is the PRIMARY
    # mechanism. sshd routes password attempts through the Windows logon stack
    # which validates against Active Directory. The administrators_authorized_keys
    # file is OPTIONAL -- only needed for public-key fallback.
    OpenSshStageDir        = 'C:\Tools\openssh'
    OpenSshZipLocal        = 'C:\Tools\openssh\OpenSSH-Win64.zip'
    OpenSshAuthKeysSource  = 'C:\Tools\openssh\administrators_authorized_keys'
    OpenSshInstallDir      = 'C:\Program Files\OpenSSH'
    OpenSshAuthKeysTarget  = 'C:\ProgramData\ssh\administrators_authorized_keys'
    OpenSshFirewallRule    = 'OpenSSH-Server-In-TCP'
    # Restrict SSH login to specific AD groups. Empty array = no restriction
    # (default sshd behaviour: any user with valid creds + "log on locally"
    # right). Format: "DOMAIN\Group Name".
    OpenSshAllowedADGroups = @(
        # 'KAYHUT\Domain Admins',
        # 'KAYHUT\DevOps-Engineers'
    )

    # --- Paths (E: drive preferred -- resolved from $DataDrive) ---
    BuildsDir        = "$Script:DataDrive\GitLab-Runner\builds"
    CacheDir         = "$Script:DataDrive\GitLab-Runner\cache"
    DockerDataRoot   = "$Script:DataDrive\docker-data"

    # --- Phase Markers ---
    Phase1Marker     = 'C:\GitLab-Runner\.phase1_complete'
    Phase2Marker     = 'C:\GitLab-Runner\.phase2_complete'
    Phase3Marker     = 'C:\GitLab-Runner\.phase3_complete'
    # Set by Phase 1 step 1.9 when the host doesn't expose VT-x; read by
    # Invoke-FinalValidation in Phase 3 (different process after the reboot,
    # so an in-memory variable wouldn't survive).
    HyperVSkippedMarker = 'C:\GitLab-Runner\.hyperv_skipped'

    # --- Thresholds ---
    # Completion markers are DURABLE and never expire -- Test-PhaseComplete
    # checks existence only. A phase writes its marker just once, on full
    # success; a crash mid-phase leaves no marker and the phase re-runs on the
    # next boot. No time-based staleness (StaleMinutes is retired).
    PagefileMaxMB    = 32768

    # --- Runner defaults ---
    ConcurrentJobs   = 2
    CheckInterval    = 3
    # config.toml tuning (was hardcoded in Phase 3). Process isolation,
    # WS2019 host + ltsc2019 containers. ShmSize in bytes (256 MB).
    Runner = @{
        ShutdownTimeout        = 300
        LogLevel               = 'info'
        PullPolicy             = 'if-not-present'
        Isolation              = 'process'
        Privileged             = $false
        TlsVerify              = $false
        ShmSize                = 268435456
        WaitForServicesTimeout = 30
        DisableCache           = $false
        CacheType              = ''
    }

    # --- MinIO object keys ---
    # --- MinIO object keys -- core binaries + maintenance scripts ---
    # Tools (WinRAR, NSSM, Sysinternals, Notepad++, etc.) and observability
    # exporters live in their own tables (ToolPackages, ObservabilityPackages
    # at the bottom of this file). This table only holds the runtime essentials
    # downloaded by Phase 2 (Docker/runner binaries) and Phase 3 (maintenance scripts).
    S3Keys = @{
        RunnerBin    = 'binaries/gitlab-runner-16.7.0-windows-amd64.exe'
        DockerExe    = 'binaries/docker/docker.exe'
        DockerdExe   = 'binaries/docker/dockerd.exe'
        MinGitZip    = 'binaries/git/MinGit-2.43.0-64-bit.zip'
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

    # --- Bootstrap S3 keys (downloaded by Phase 0 in Bootstrap-GitLabRunner.ps1) ---
    S3Bootstrap = @{
        Config         = 'bootstrap/lib/Config.ps1'
        Common         = 'bootstrap/lib/Common.ps1'
        Phase1         = 'bootstrap/phases/Phase1-SystemPrep.ps1'
        Phase2         = 'bootstrap/phases/Phase2-DockerInstall.ps1'
        Phase3         = 'bootstrap/phases/Phase3-RunnerSetup.ps1'
        FinalValid     = 'bootstrap/validation/Invoke-FinalValidation.ps1'
    }

    # --- MinIO object keys -- auxiliary scripts and one-shot binaries ---
    # Test-Dependencies.ps1 enumerates this hashtable verbatim, so adding a
    # key here automatically gets it pre-flight checked. Remove a key only
    # when the corresponding object has been deleted from MinIO.
    S3KeysExtra = @{
        # --- Scripts -----------------------------------------------------------
        ImportCerts          = 'scripts/Import-Certificates.ps1'
        EnableRemoteSSH      = 'scripts/Enable-RemoteSSH.ps1'
        NetMonitor           = 'scripts/Test-NetworkConnectivity.ps1'
        JobLog               = 'scripts/Write-JobLog.ps1'
        RdpAudit             = 'scripts/Export-RdpAuditLog.ps1'
        LogCollector         = 'scripts/Export-RunnerLogs.ps1'
        GoldenVersion        = 'scripts/Write-GoldenVersion.ps1'
        InstallOpenCode      = 'scripts/Install-OpenCode.ps1'
        InstallTools         = 'scripts/Install-Tools.ps1'
        InstallObservability = 'scripts/Install-Observability.ps1'
        SetWtDefault         = 'scripts/Set-WindowsTerminalDefault.ps1'
        FirstBootRegister    = 'provisioners/Register-RunnerFirstBoot.ps1'
        DepValidator         = 'validation/Test-Dependencies.ps1'
        AssertEnv            = 'scripts/Assert-Environment.ps1'
        ThemeScript          = 'scripts/Set-RunnerTheme.ps1'

        # --- OpenCode + WebView2 ---------------------------------------------
        WebView2Exe          = 'tools/opencode/MicrosoftEdgeWebView2RuntimeInstallerX64.exe'
        OpenCodeExe          = 'tools/opencode/opencode-desktop-windows-x64-setup.exe'
        OpenCodeConfig       = 'tools/opencode/opencode.jsonc'

        # --- OpenSSH ---------------------------------------------------------
        OpenSshZip           = 'tools/openssh/OpenSSH-Win64.zip'
        OpenSshAuthKeys      = 'tools/openssh/administrators_authorized_keys'
    }

    # --- Golden image version ---
    GoldenImageVersion = '2.4.0'

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
    "${_gitLabRegistry}/${_registryProject}/gitlab-runner-helper:x86_64-v16.7.0-servercore1809",
    "${_gitLabRegistry}/${_registryProject}/servercore:ltsc2019",
    "${_gitLabRegistry}/${_registryProject}/windows:ltsc2019"
)

$Script:Config.HelperImage = "${_gitLabRegistry}/${_registryProject}/gitlab-runner-helper:x86_64-v16.7.0-servercore1809"

$Script:Config.InsecureRegistries = @(
    $_gitLabRegistry,
    $_artifactoryHost
)

$Script:Config.MonitorHosts = @(
    @{ Host = $_gitLabHost;       Port = 443          },
    @{ Host = $_minioHost;        Port = $_minioPort   },
    @{ Host = $_artifactoryHost;  Port = 443          },
    @{ Host = $_be1Host;          Port = 443          }
)

# ============================================================
# OBSERVABILITY -- ports for the Prometheus stack
# Used by Install-Observability.ps1, daemon.json (Phase 2),
# config.toml (Phase 3), and Invoke-FinalValidation.ps1.
# ============================================================
$Script:Config.MetricsPorts = @{
    WindowsExporter  = 9182
    BlackboxExporter = 9115
    GitLabRunner     = 9252
    Docker           = 9323
}

# ============================================================
# TOOL PACKAGES -- consumed by Install-Tools.ps1
# Append a new entry to add a tool. Install-Tools iterates this table verbatim.
# Required fields: Name, S3Key, InstallType, Detect (scriptblock).
# Optional:        StageDir, ExtractTo, DestPath, InstallArgs, Dependencies,
#                  PostInstall.
# ============================================================
$Script:Config.ToolPackages = @(
    # ----- Operator core (already in the image previously) --------------
    @{
        Name        = 'WinRAR'
        S3Key       = 'tools/winrar/winrar-x64-701.exe'
        StageDir    = 'C:\Tools\winrar'
        InstallType = 'exe'
        InstallArgs = @('/s')
        Detect      = { Test-Path 'C:\Program Files\WinRAR\WinRAR.exe' }
    }
    @{
        Name        = 'NSSM'
        S3Key       = 'tools/nssm/nssm-2.24.zip'
        StageDir    = 'C:\Tools\nssm-stage'
        InstallType = 'zip'
        ExtractTo   = 'C:\Tools'
        Detect      = { Test-Path 'C:\Tools\nssm.exe' }
        # Zip extracts to nssm-2.24\win64\nssm.exe -- promote it to C:\Tools\nssm.exe
        PostInstall = {
            $found = Get-ChildItem 'C:\Tools' -Recurse -Filter 'nssm.exe' -EA SilentlyContinue |
                     Where-Object { $_.FullName -like '*win64*' } | Select-Object -First 1
            if ($found) { Copy-Item $found.FullName 'C:\Tools\nssm.exe' -Force }
        }
    }
    @{
        Name        = 'Sysinternals'
        S3Key       = 'tools/sysinternals/SysinternalsSuite.zip'
        StageDir    = 'C:\Tools\sysinternals-stage'
        InstallType = 'zip'
        ExtractTo   = 'C:\Tools\SysInternals'
        Detect      = { Test-Path 'C:\Tools\SysInternals\procexp64.exe' }
    }

    # ----- File / log inspection ----------------------------------------
    @{
        Name        = 'Notepad++'
        S3Key       = 'tools/notepadpp/npp.8.9.4.Installer.x64.exe'
        StageDir    = 'C:\Tools\notepadpp'
        InstallType = 'exe'
        InstallArgs = @('/S')
        Detect      = { Test-Path 'C:\Program Files\Notepad++\notepad++.exe' }
    }
    @{
        Name        = 'WinMerge'
        S3Key       = 'tools/winmerge/WinMerge-2.16.56-x64-Setup.exe'
        StageDir    = 'C:\Tools\winmerge'
        InstallType = 'exe'
        InstallArgs = @('/SP-','/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
        Detect      = { Test-Path 'C:\Program Files\WinMerge\WinMergeU.exe' }
    }
    @{
        Name        = 'BareTail'
        S3Key       = 'tools/baretail/baretail.exe'
        InstallType = 'copy'
        DestPath    = 'C:\Program Files\BareTail\baretail.exe'
        Detect      = { Test-Path 'C:\Program Files\BareTail\baretail.exe' }
    }
    @{
        Name        = 'Klogg'
        # The 22.06 release ships only Qt5 + Qt6 setup variants. Qt6 needs
        # Win10 1809+, so we use the Qt5 build for WS2019 LTSC compatibility.
        S3Key       = 'tools/klogg/klogg-22.06.0.1289-Win-x64-Qt5-setup.exe'
        StageDir    = 'C:\Tools\klogg'
        InstallType = 'exe'
        InstallArgs = @('/S')
        Detect      = { Test-Path 'C:\Program Files\klogg\klogg.exe' }
    }

    # ----- Filesystem / disk -------------------------------------------
    @{
        Name        = 'Everything'
        S3Key       = 'tools/everything/Everything-1.4.1.1027.x64-Setup.exe'
        StageDir    = 'C:\Tools\everything'
        InstallType = 'exe'
        InstallArgs = @('/S','/install-service','/install-quick-launch-shortcut=0','/install-desktop-shortcut=0')
        Detect      = { Test-Path 'C:\Program Files\Everything\Everything.exe' }
    }
    @{
        Name        = 'WizTree'
        S3Key       = 'tools/wiztree/WizTree4.exe'
        InstallType = 'copy'
        DestPath    = 'C:\Program Files\WizTree\WizTree.exe'
        Detect      = { Test-Path 'C:\Program Files\WizTree\WizTree.exe' }
    }

    # ----- System inspection -------------------------------------------
    @{
        Name        = 'SystemInformer'
        # 3.2.x releases were unpublished; 4.x is the current stable line.
        # 4.x dropped the per-arch subfolder layout (amd64/ + i386/) -- the
        # win64-bin zip now ships SystemInformer.exe + .sys at the root.
        S3Key       = 'tools/systeminformer/systeminformer-4.0.26115.206-win64-bin.zip'
        StageDir    = 'C:\Tools\systeminformer-stage'
        InstallType = 'zip'
        ExtractTo   = 'C:\Program Files\SystemInformer'
        Detect      = { Test-Path 'C:\Program Files\SystemInformer\SystemInformer.exe' }
    }
    @{
        Name        = 'EventLook'
        # kmaki565/EventLook 1.6.4.0 -- WPF Windows event-log viewer.
        # The bin zip's filename embeds a commit hash; bumping versions
        # means updating this S3Key + the URL in any external fetcher.
        S3Key       = 'tools/eventlook/EventLook-bin-18e54c9.zip'
        StageDir    = 'C:\Tools\eventlook-stage'
        InstallType = 'zip'
        ExtractTo   = 'C:\Program Files\EventLook'
        Detect      = { Test-Path 'C:\Program Files\EventLook\EventLook.exe' }
    }

    # ----- Network ------------------------------------------------------
    @{
        Name        = 'Wireshark+tshark'
        S3Key       = 'tools/wireshark/Wireshark-4.4.6-x64.exe'
        StageDir    = 'C:\Tools\wireshark'
        InstallType = 'exe'
        InstallArgs = @('/S','/desktopicon=no','/quicklaunchicon=no')
        Detect      = { Test-Path 'C:\Program Files\Wireshark\tshark.exe' }
    }

    # ----- Browser / Terminal / convenience -----------------------------
    @{
        Name        = 'Chrome'
        S3Key       = 'tools/chrome/ChromeStandaloneSetup64.exe'
        StageDir    = 'C:\Tools\chrome'
        InstallType = 'exe'
        InstallArgs = @('/silent','/install')
        Detect      = { Test-Path 'C:\Program Files\Google\Chrome\Application\chrome.exe' }
    }
    @{
        Name        = 'WindowsTerminal'
        # Portable zip works on WS2019; the msixbundle 1.21+ requires Win11.
        # 1.18 line is the last that supports WS2019. Use the portable zip
        # build (no AppX runtime needed) and extract to Program Files.
        S3Key       = 'tools/terminal/Microsoft.WindowsTerminal_1.18.3181.0_x64.zip'
        StageDir    = 'C:\Tools\terminal'
        InstallType = 'zip'
        ExtractTo   = 'C:\Program Files\WindowsTerminal'
        Detect      = { Test-Path 'C:\Program Files\WindowsTerminal\wt.exe' }
        # Configure as default UX for PS + CMD via portable-mode marker +
        # machine-wide settings.json + Default User Start Menu shortcuts.
        # Implementation in scripts/Set-WindowsTerminalDefault.ps1.
        PostInstall = {
            $scr = 'C:\GitLab-Runner\scripts\Set-WindowsTerminalDefault.ps1'
            if (Test-Path $scr) {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scr `
                    -InstallDir 'C:\Program Files\WindowsTerminal' 2>&1 | Out-Host
            }
        }
    }
)

# ============================================================
# OBSERVABILITY PACKAGES -- consumed by Install-Observability.ps1
# These need extra service/firewall plumbing so they stay separate from
# the generic ToolPackages table.
# ============================================================
$Script:Config.ObservabilityPackages = @{
    WindowsExporter = @{
        S3Key        = 'tools/observability/windows_exporter-0.31.6-amd64.msi'
        LocalPath    = 'C:\Tools\windows_exporter\windows_exporter.msi'
        ServiceName  = 'windows_exporter'
        Port         = 9182
    }
    BlackboxExporter = @{
        S3Key        = 'tools/observability/blackbox_exporter-0.28.0.windows-amd64.zip'
        LocalPath    = 'C:\Tools\blackbox_exporter\blackbox_exporter.zip'
        # InstallDir intentionally has NO spaces -- NSSM stores AppParameters
        # as a raw whitespace-split string at service runtime, so a path with
        # spaces would tokenise as multiple args and the exporter would fail.
        InstallDir   = 'C:\Tools\blackbox_exporter'
        ServiceName  = 'blackbox_exporter'
        Port         = 9115
    }
}
