#Requires -RunAsAdministrator
<#
.SYNOPSIS
    First-boot runner registration for the generic golden image. Reads the
    per-clone runner token + hostname from vSphere guestinfo, writes the final
    config.toml, registers if needed, and installs + starts the runner service.

.DESCRIPTION
    The golden image ships UNREGISTERED (Phase3-Install wrote only a token-less
    config.toml skeleton and did NOT install the runner service). Terraform hands
    each clone its identity at deploy time via vSphere guestinfo:
        guestinfo.runner_token     glrt-* auth token OR a PAT/registration token
        guestinfo.runner_hostname  the runner name / hostname

    This script runs once at first boot (SYSTEM startup scheduled task, installed
    at build time via -InstallStartupTask). It is IDEMPOTENT: once the runner is
    registered and the service is running, re-runs no-op. Registration + service
    start are wrapped in a retry loop because GitLab may not be reachable the
    instant the VM boots.

    Token resolution order (Get-GuestInfo): VMware Tools guestinfo -> Machine/proc
    env var -> local JSON file. So the same script is testable off-vSphere by
    setting $env:GUESTINFO_RUNNER_TOKEN / _HOSTNAME or dropping a firstboot.json.

.PARAMETER InstallStartupTask
    BUILD-TIME mode. Instead of registering the runner, register THIS script as a
    SYSTEM AtStartup scheduled task ('Runner-FirstBoot-Register') so it runs on
    every boot of the deployed clone until registration succeeds. Invoked by
    Phase3-Install during the Packer build.

.PARAMETER SelfPath
    Path the startup task should invoke (defaults to this script's own path). Used
    with -InstallStartupTask so the task points at the on-image copy in ScriptsDir.

.PARAMETER MaxAttempts
    Registration/service-start retry attempts at first boot. Default 10.

.NOTES
    File: provisioners/Register-RunnerFirstBoot.ps1
    Requires: lib/Config.ps1, lib/Common.ps1 (dot-sourced below).
    PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [switch]$InstallStartupTask,
    [string]$SelfPath = $PSCommandPath,
    [int]$MaxAttempts = 10,
    [int]$MaxBootAttempts = 5
)

$ErrorActionPreference = 'Stop'

# Run a native exe (gitlab-runner / docker), log its combined output, and RETURN
# its exit code. PS 5.1: `& exe ... 2>&1` under $ErrorActionPreference='Stop'
# promotes a benign stderr line into a TERMINATING NativeCommandError before
# $LASTEXITCODE can be read -- force Continue for the native call so success is
# judged by the exit code. Optional -StdinValue is piped in (e.g. --password-stdin)
# and is never echoed into a logged argument.
function Invoke-RunnerNative {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$NativeArgs = @(),
        [string]$Tag = 'native',
        [string]$StdinValue
    )
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    if ($PSBoundParameters.ContainsKey('StdinValue')) {
        $out = $StdinValue | & $Exe @NativeArgs 2>&1
    } else {
        $out = & $Exe @NativeArgs 2>&1
    }
    $code = $LASTEXITCODE
    foreach ($line in @($out)) { if ($null -ne $line) { Write-Log "  ${Tag}: $line" } }
    return $code
}

# --- Load Config + Common (logging, Wait-ServiceRunning, markers) ------------
# On a deployed clone this script lives in C:\GitLab-Runner\scripts, and Phase3-Install
# staged lib/ to C:\GitLab-Runner\lib -- try that first. Fall back to the repo
# layout (build/dev) and the raw C:\provision upload.
$libCandidates = @(
    'C:\GitLab-Runner\lib',                                 # staged by Phase3-Install (clone)
    (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib'),   # repo layout (../lib)
    'C:\provision\lib'                                      # raw build upload (fallback)
)
$libDir = $libCandidates | Where-Object { Test-Path (Join-Path $_ 'Config.ps1') } | Select-Object -First 1
if (-not $libDir) { throw 'Cannot locate lib/Config.ps1 (need Config.ps1 + Common.ps1).' }
. (Join-Path $libDir 'Config.ps1')
. (Join-Path $libDir 'Common.ps1')
$Script:Component = 'firstboot'

# Make the deploy-gate (Test-RunnerRegistered) available -- it lives in the
# validation file, which Phase3-Install staged alongside lib/.
$valCandidates = @(
    (Join-Path $Script:Config.RunnerDir 'validation\Invoke-FinalValidation.ps1'),
    (Join-Path (Split-Path $PSScriptRoot -Parent) 'validation\Invoke-FinalValidation.ps1'),
    'C:\provision\validation\Invoke-FinalValidation.ps1'
)
$valFile = $valCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($valFile) { . $valFile } else { Write-LogWarn 'Invoke-FinalValidation.ps1 not found -- deploy-gate will be skipped.' }

$Script:FirstBootMarker = Join-Path $Script:Config.RunnerDir '.firstboot_complete'
$Script:FirstBootTask   = 'Runner-FirstBoot-Register'

# ============================================================
# BUILD-TIME: register this script as a SYSTEM AtStartup task
# ============================================================
if ($InstallStartupTask) {
    Write-Log "Installing '$Script:FirstBootTask' SYSTEM startup task -> $SelfPath"
    # Reuse the Register-ScheduledTasks.ps1 SYSTEM principal pattern.
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$SelfPath`""
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
                    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
                    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $Script:FirstBootTask -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log "  '$Script:FirstBootTask' registered (runs as SYSTEM AtStartup)."
    return
}

# ============================================================
# RUNTIME (first boot): resolve identity + register
# ============================================================

function Get-GuestInfo {
    <#
    .SYNOPSIS  Read a value from vSphere guestinfo, else env, else local JSON file.
    #>
    param([Parameter(Mandatory)][string]$Key)

    # PS5.1: `& native 2>$null` under EAP=Stop throws a terminating error the instant
    # the process writes to stderr -- vmtoolsd does on a missing key. Force Continue
    # so a missing/blank guestinfo value falls through to the next source, not throws.
    $ErrorActionPreference = 'Continue'

    # 1. VMware Tools guestinfo
    $vmtoolsd = $null
    $cmd = Get-Command vmtoolsd.exe -ErrorAction SilentlyContinue
    if ($cmd) { $vmtoolsd = $cmd.Source }
    elseif (Test-Path 'C:\Program Files\VMware\VMware Tools\vmtoolsd.exe') {
        $vmtoolsd = 'C:\Program Files\VMware\VMware Tools\vmtoolsd.exe'
    }
    if ($vmtoolsd) {
        $global:LASTEXITCODE = 0
        $raw  = & $vmtoolsd --cmd "info-get guestinfo.$Key" 2>$null
        $code = $LASTEXITCODE
        $val  = ((@($raw) | ForEach-Object { "$_" }) -join "`n").Trim()
        if ($code -eq 0 -and $val) { return $val }
    }

    # 2. environment variable (GUESTINFO_<KEY>, machine scope then process)
    $envName = "GUESTINFO_$($Key.ToUpper())"
    $envVal  = [System.Environment]::GetEnvironmentVariable($envName, 'Machine')
    if (-not $envVal) { $envVal = [System.Environment]::GetEnvironmentVariable($envName, 'Process') }
    if ($envVal) { return $envVal.Trim() }

    # 3. local JSON file fallback (firstboot.json under RunnerDir)
    $jsonPath = Join-Path $Script:Config.RunnerDir 'firstboot.json'
    if (Test-Path $jsonPath) {
        try {
            $obj = Get-Content $jsonPath -Raw | ConvertFrom-Json
            if ($obj.PSObject.Properties.Name -contains $Key -and $obj.$Key) { return ([string]$obj.$Key).Trim() }
        } catch { Write-LogWarn "firstboot.json parse failed: $_" }
    }
    return $null
}

function Write-RunnerConfigToml {
    <#
    .SYNOPSIS  Write the final config.toml (token + name + full runner block).
    .NOTES     Lifted from the former Phase3 3.6-3.7. Booleans stringified lowercase
               for TOML; backslashes doubled for the Windows volume paths.
    #>
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$HostName)

    $r          = $Script:Config.Runner
    $rPriv      = $r.Privileged.ToString().ToLower()
    $rTls       = $r.TlsVerify.ToString().ToLower()
    $rNoCac     = $r.DisableCache.ToString().ToLower()
    $buildsVol  = "$($Script:Config.BuildsDir -replace '\\','\\'):C:\\builds"
    $cacheVol   = "$($Script:Config.CacheDir  -replace '\\','\\'):C:\\cache"
    $defaultImage = "$($Script:Config.RegistryHost)/$($Script:Config.RegistryProject)/servercore:ltsc2019"
    $scriptsEsc = $Script:Config.ScriptsDir -replace '\\', '\\'

    $configContent = @"
# GitLab Runner Configuration -- Auto-generated at first boot
# Host: $HostName | Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

concurrent = $($Script:Config.ConcurrentJobs)
check_interval = $($Script:Config.CheckInterval)
shutdown_timeout = $($r.ShutdownTimeout)
log_level = "$($r.LogLevel)"

listen_address = ":$($Script:Config.MetricsPorts.GitLabRunner)"

[[runners]]
  name = "runner-$HostName"
  url = "$($Script:Config.GitLabUrl)"
  token = "$Token"
  executor = "docker-windows"
  tls-verify = $rTls
  environment = ["GIT_SSL_NO_VERIFY=true", "DOCKER_TLS_CERTDIR="]
  pre_build_script = "powershell -NoProfile -ExecutionPolicy Bypass -File ${scriptsEsc}\\Write-JobLog.ps1 -Action start"
  post_build_script = "powershell -NoProfile -ExecutionPolicy Bypass -File ${scriptsEsc}\\Write-JobLog.ps1 -Action end"

  [runners.docker]
    image = "$defaultImage"
    helper_image = "$($Script:Config.HelperImage)"
    isolation = "$($r.Isolation)"
    pull_policy = ["$($r.PullPolicy)"]
    tls_verify = $rTls
    privileged = $rPriv
    shm_size = $($r.ShmSize)
    volumes = ["$buildsVol", "$cacheVol"]
    allowed_images = []
    allowed_services = []
    wait_for_services_timeout = $($r.WaitForServicesTimeout)
    disable_cache = $rNoCac

  [runners.cache]
    Type = "$($r.CacheType)"
"@
    $configContent | Out-File -FilePath $Script:Config.ConfigToml -Encoding UTF8 -Force
    Write-Log "config.toml written for runner-$HostName"
}

function Test-AlreadyRegistered {
    # Registered == the service is Running AND config.toml carries a glrt- token.
    # Idempotency is based on live state (not the marker alone) so a stale marker
    # baked into a clone can't mask an unregistered runner. Also re-register if a
    # glrt- token arrives via guestinfo that differs from config.toml (rotation).
    if ((Get-Service gitlab-runner -ErrorAction SilentlyContinue).Status -ne 'Running') { return $false }
    $cfg = Get-Content $Script:Config.ConfigToml -Raw -ErrorAction SilentlyContinue
    if ($cfg -notmatch 'token\s*=\s*"(glrt-[^"]+)"') { return $false }
    $current = $Matches[1]
    $gi = Get-GuestInfo -Key 'runner_token'
    if ($gi -and $gi -match '^glrt-' -and $gi -ne $current) {
        Write-Log 'guestinfo runner_token differs from config.toml -- re-registering (token rotation).'
        return $false
    }
    return $true
}

function Invoke-Registration {
    # Resolve identity
    $token = Get-GuestInfo -Key 'runner_token'
    if (-not $token) { $token = [System.Environment]::GetEnvironmentVariable('GITLAB_RUNNER_TOKEN', 'Machine') }
    if (-not $token) {
        Write-LogError 'FATAL: runner token not found (guestinfo.runner_token / GUESTINFO_RUNNER_TOKEN / firstboot.json).'
        return $false
    }
    $hostName = Get-GuestInfo -Key 'runner_hostname'
    if (-not $hostName) { $hostName = $env:COMPUTERNAME }

    $isAuthToken = $token -match '^glrt-'
    Write-Log ("Token type: {0}" -f $(if ($isAuthToken) { 'Runner Authentication Token (glrt-***)' } else { 'Registration Token / PAT (will register first)' }))

    # Register a PAT/registration token to obtain the glrt- auth token
    if (-not $isAuthToken) {
        Write-Log 'Registering runner with GitLab (registration token / PAT)'
        $defaultImage = "$($Script:Config.RegistryHost)/$($Script:Config.RegistryProject)/servercore:ltsc2019"
        # --config is REQUIRED: without it gitlab-runner writes the emitted glrt-
        # token to its DEFAULT config path, and the extraction below (which reads
        # $Script:Config.ConfigToml) would never find it -- the whole PAT path would
        # abort. Invoke-RunnerNative forces ErrorActionPreference=Continue so a
        # benign stderr line can't throw under Stop before the exit code is read.
        $regRc = Invoke-RunnerNative -Exe $Script:Config.RunnerBin -Tag 'register' -NativeArgs @(
            'register',
            '--non-interactive',
            '--config', $Script:Config.ConfigToml,
            '--url', $Script:Config.GitLabUrl,
            '--registration-token', $token,
            '--executor', 'docker-windows',
            '--docker-image', $defaultImage,
            '--name', "runner-$hostName"
        )
        if ($regRc -ne 0) {
            Write-LogError "Runner registration FAILED (exit $regRc) -- token invalid or GitLab unreachable."
            return $false
        }
        $regConfig = Get-Content $Script:Config.ConfigToml -Raw -ErrorAction SilentlyContinue
        if ($regConfig -match 'token\s*=\s*"(glrt-[^"]+)"') {
            $token = $Matches[1]
            Write-Log 'Extracted auth token: glrt-***'
        } else {
            Write-LogError 'Registration returned 0 but no glrt- token found in config.toml -- aborting.'
            return $false
        }
    }

    # Write the final config.toml with the resolved auth token
    Write-RunnerConfigToml -Token $token -HostName $hostName

    # Install + start the runner service (idempotent)
    if (Get-Service gitlab-runner -ErrorAction SilentlyContinue) {
        Write-Log '  Existing gitlab-runner service -- stop + uninstall before reinstall'
        [void](Invoke-RunnerNative -Exe $Script:Config.RunnerBin -Tag 'stop'      -NativeArgs @('stop'))
        [void](Invoke-RunnerNative -Exe $Script:Config.RunnerBin -Tag 'uninstall' -NativeArgs @('uninstall'))
        Start-Sleep -Seconds 2
    }
    [void](Invoke-RunnerNative -Exe $Script:Config.RunnerBin -Tag 'install' -NativeArgs @(
        'install', '--working-directory', $Script:Config.RunnerDir, '--config', $Script:Config.ConfigToml))
    [void](Invoke-RunnerNative -Exe $Script:Config.RunnerBin -Tag 'start' -NativeArgs @('start'))

    if (-not (Wait-ServiceRunning -Name 'gitlab-runner' -TimeoutSeconds 30 -PollSeconds 3)) {
        Write-LogError 'gitlab-runner service failed to start.'
        return $false
    }

    # Registry login in THIS (SYSTEM) context so the runner service's
    # systemprofile .docker\config.json carries creds for RUNTIME private-image
    # pulls -- the build-time login ran as a different user (Administrator).
    # Creds arrive per-clone via guestinfo (registry_user/registry_pass); empty
    # => anonymous (only pre-pulled images will be available). Never logged.
    $ru = Get-GuestInfo -Key 'registry_user'
    $rp = Get-GuestInfo -Key 'registry_pass'
    if ($ru -and $rp) {
        Write-Log "Registry login as SYSTEM ($(whoami)) -> $($Script:Config.GitLabRegistry) (user '$ru')"
        $loginRc = Invoke-RunnerNative -Exe 'docker' -Tag 'registry login' -StdinValue $rp -NativeArgs @(
            'login', $Script:Config.GitLabRegistry, '-u', $ru, '--password-stdin')
        if ($loginRc -ne 0) {
            Write-LogWarn "SYSTEM registry login FAILED (exit $loginRc) -- runtime pulls of private images will fail until fixed."
        }
    } else {
        Write-LogWarn 'No guestinfo registry creds -- SYSTEM runner can pull only pre-baked images (anonymous).'
    }
    return $true
}

function Initialize-DataDisk {
    <#
    .SYNOPSIS  Bring the per-clone data disk online as E: (idempotent). Returns
               'E:' on success, 'C:' if no separate fixed data disk is present.
    .DESCRIPTION
        The Aria catalog attaches the raw data disk (vm_inputs.data_disk_gb), but
        Windows must initialize + format it. The golden image was BUILT with only
        C:, so $DataDrive froze to C: at Config load -- without this step docker
        storage + builds fill the ~100 GB OS disk and the 2 TB data disk sits raw.
        Guards on BusType != USB so an NTFS USB can't latch as the data drive.
    #>
    if (Test-Path 'E:\') {
        $vol = Get-Volume -DriveLetter E -ErrorAction SilentlyContinue
        if ($vol -and $vol.DriveType -eq 'Fixed' -and $vol.FileSystemType -eq 'NTFS') {
            Write-Log 'Data disk: E: already online (Fixed/NTFS).'; return 'E:'
        }
        Write-LogWarn 'E: exists but is not a Fixed NTFS volume -- runner data falls back to C:.'
        return 'C:'
    }
    $raw = Get-Disk -ErrorAction SilentlyContinue |
        Where-Object { ($_.PartitionStyle -eq 'RAW' -or $_.NumberOfPartitions -eq 0) -and $_.BusType -ne 'USB' } |
        Sort-Object Number | Select-Object -First 1
    if (-not $raw) { Write-LogWarn 'No raw fixed data disk found -- runner data falls back to C:.'; return 'C:' }
    Write-Log "Initializing data disk #$($raw.Number) (~$([math]::Round($raw.Size/1GB)) GB) as E:"
    try {
        Initialize-Disk -Number $raw.Number -PartitionStyle GPT -ErrorAction Stop
        New-Partition -DiskNumber $raw.Number -DriveLetter E -UseMaximumSize -ErrorAction Stop | Out-Null
        Format-Volume -DriveLetter E -FileSystem NTFS -NewFileSystemLabel 'RunnerData' -Confirm:$false -Force -ErrorAction Stop | Out-Null
        Write-Log 'Data disk initialized + formatted NTFS as E:.'; return 'E:'
    } catch {
        Write-LogError "Data disk init failed: $($_.Exception.Message) -- falling back to C:."; return 'C:'
    }
}

function Set-DataDrivePaths {
    <#
    .SYNOPSIS  Repoint the data-dependent Config paths + docker data-root onto
               $Drive, MOVING the existing data-root so the multi-GB pre-pulled
               ltsc2019 images survive (built onto C:). Idempotent.
    #>
    param([Parameter(Mandatory)][string]$Drive)
    if ($Drive -eq 'C:') { return }

    $oldRoot = $Script:Config.DockerDataRoot           # baked at build: C:\docker-data
    $newRoot = "$Drive\docker-data"
    # Repoint in-memory Config so Write-RunnerConfigToml emits E: volumes.
    $Script:Config.BuildsDir      = "$Drive\GitLab-Runner\builds"
    $Script:Config.CacheDir       = "$Drive\GitLab-Runner\cache"
    $Script:Config.DockerDataRoot = $newRoot
    foreach ($d in @($Script:Config.BuildsDir, $Script:Config.CacheDir)) {
        if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
    }

    $daemon = Get-Content $Script:Config.DaemonJson -Raw -ErrorAction SilentlyContinue
    if ($daemon -and $daemon -match ('"data-root"\s*:\s*"' + [regex]::Escape($Drive.TrimEnd(':')) + ':')) {
        Write-Log "docker data-root already on $Drive."; return
    }
    if ($oldRoot -eq $newRoot) { return }

    Write-Log "Moving docker data-root $oldRoot -> $newRoot (preserves pre-pulled images)"
    Stop-Service docker -Force -ErrorAction SilentlyContinue
    $rc = Invoke-RunnerNative -Exe 'robocopy' -Tag 'robocopy data-root' -NativeArgs @(
        $oldRoot, $newRoot, '/E', '/MOVE', '/COPYALL', '/R:1', '/W:1', '/NFL', '/NDL', '/NP')
    if ($rc -ge 8) {   # robocopy exit 0-7 = success, >=8 = failure
        Write-LogError "robocopy data-root move failed (exit $rc) -- keeping docker on $oldRoot."
        $Script:Config.DockerDataRoot = $oldRoot
        Start-Service docker -ErrorAction SilentlyContinue
        return
    }
    if ($daemon) {
        $escNew = ($newRoot -replace '\\', '\\')
        ($daemon -replace '("data-root"\s*:\s*")[^"]*(")', ('${1}' + $escNew + '${2}')) |
            Out-File -FilePath $Script:Config.DaemonJson -Encoding UTF8 -Force
        Write-Log "daemon.json data-root rewritten to $newRoot."
    }
    Start-Service docker -ErrorAction SilentlyContinue
    for ($i = 1; $i -le 12; $i++) {
        & { $ErrorActionPreference = 'Continue'; docker info 2>&1 | Out-Null }
        if ($LASTEXITCODE -eq 0) { Write-Log 'docker ready on new data-root.'; break }
        Start-Sleep -Seconds 5
    }
}

# --- Main (runtime) ----------------------------------------------------------
Write-Log '========== FIRST-BOOT RUNNER REGISTRATION =========='

# Bring the per-clone data disk online + move docker storage onto it BEFORE
# registration, so config.toml volumes and docker images land on E:, not the OS
# disk. Idempotent: a no-op once E: is online and docker is already rooted there.
$Script:DataDrive = Initialize-DataDisk
Set-DataDrivePaths -Drive $Script:DataDrive

if (Test-AlreadyRegistered) {
    Write-Log 'Runner already registered and service running -- nothing to do.'
    Set-PhaseMarker $Script:FirstBootMarker
    return
}

$ok = $false
for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    Write-Log "Registration attempt $attempt/$MaxAttempts"
    try {
        if (Invoke-Registration) { $ok = $true; break }
    } catch {
        Write-LogError "Registration attempt $attempt threw: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds ([Math]::Min(60, 5 * $attempt))
}

if (-not $ok) {
    # Cumulative across boots: a permanently-bad token would otherwise loop every
    # boot forever with no operator signal. After $MaxBootAttempts boots, raise a
    # visible Event Log error + a breadcrumb so the fleet health check sees it.
    $attemptsFile = Join-Path $Script:Config.RunnerDir '.firstboot_attempts'
    $boots = 0
    if (Test-Path $attemptsFile) { [int]::TryParse((Get-Content $attemptsFile -Raw).Trim(), [ref]$boots) | Out-Null }
    $boots++
    $boots | Out-File -FilePath $attemptsFile -Encoding ascii -Force
    Write-LogError "First-boot registration failed after $MaxAttempts attempts (boot #$boots/$MaxBootAttempts)."
    if ($boots -ge $MaxBootAttempts) {
        $msg = "Runner first-boot registration FAILED on $boots boots -- check the runner token / GitLab reachability. Host: $env:COMPUTERNAME."
        Write-LogError $msg
        New-Item -Path (Join-Path $Script:Config.RunnerDir '.firstboot_failed') -ItemType File -Force | Out-Null
        try {
            if ([System.Diagnostics.EventLog]::SourceExists('GitLabRunner')) {
                Write-EventLog -LogName Application -Source 'GitLabRunner' -EventId 9015 -EntryType Error -Message $msg -ErrorAction Stop
            }
        } catch { Write-LogWarn "Event log write failed (non-fatal): $_" }
    } else {
        Write-LogError 'The startup task will retry on next boot.'
    }
    exit 1
}
# Success -- clear the cross-boot attempt counter.
Remove-Item (Join-Path $Script:Config.RunnerDir '.firstboot_attempts') -Force -ErrorAction SilentlyContinue

# Deploy-gate (added by T05). Fatal here: a clone that registered but cannot
# verify is not operational, so do not set the firstboot marker.
if (Get-Command Test-RunnerRegistered -ErrorAction SilentlyContinue) {
    if (Test-RunnerRegistered) { Write-Log 'Deploy-gate Test-RunnerRegistered PASSED.' }
    else {
        Write-LogError 'FATAL: Deploy-gate Test-RunnerRegistered FAILED; leaving firstboot marker unset.'
        New-Item -Path (Join-Path $Script:Config.RunnerDir '.firstboot_failed') -ItemType File -Force | Out-Null
        exit 1
    }
} else {
    Write-LogError 'FATAL: deploy-gate Test-RunnerRegistered is unavailable; leaving firstboot marker unset.'
    exit 1
}

Set-PhaseMarker $Script:FirstBootMarker
Write-Log '========== FIRST-BOOT REGISTRATION COMPLETE -- RUNNER OPERATIONAL =========='
