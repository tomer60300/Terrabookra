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
    [int]$MaxAttempts = 10
)

$ErrorActionPreference = 'Stop'

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
        # Capture output + exit code BEFORE the logging pipeline: `2>&1 | ForEach`
        # under ErrorActionPreference='Stop' can turn a stderr line into a
        # terminating error, and the trailing cmdlet would leave $LASTEXITCODE
        # reflecting the cmdlet, not gitlab-runner.
        $regOut = & $Script:Config.RunnerBin register `
            --non-interactive `
            --url $Script:Config.GitLabUrl `
            --registration-token $token `
            --executor docker-windows `
            --docker-image $defaultImage `
            --tls-ca-file "" `
            --name "runner-$hostName" 2>&1
        $regRc = $LASTEXITCODE
        $regOut | ForEach-Object { Write-Log "  register: $_" }
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
        & $Script:Config.RunnerBin stop      2>&1 | ForEach-Object { Write-Log "  stop: $_" }
        & $Script:Config.RunnerBin uninstall 2>&1 | ForEach-Object { Write-Log "  uninstall: $_" }
        Start-Sleep -Seconds 2
    }
    & $Script:Config.RunnerBin install `
        --working-directory $Script:Config.RunnerDir `
        --config $Script:Config.ConfigToml 2>&1 | ForEach-Object { Write-Log "  install: $_" }
    & $Script:Config.RunnerBin start 2>&1 | ForEach-Object { Write-Log "  start: $_" }

    if (-not (Wait-ServiceRunning -Name 'gitlab-runner' -TimeoutSeconds 30 -PollSeconds 3)) {
        Write-LogError 'gitlab-runner service failed to start.'
        return $false
    }
    return $true
}

# --- Main (runtime) ----------------------------------------------------------
Write-Log '========== FIRST-BOOT RUNNER REGISTRATION =========='

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
    Write-LogError "First-boot registration did not succeed after $MaxAttempts attempts -- the startup task will retry on next boot."
    exit 1
}

# Optional deploy-gate (added by T05). Run it if present; never fatal here.
if (Get-Command Test-RunnerRegistered -ErrorAction SilentlyContinue) {
    if (Test-RunnerRegistered) { Write-Log 'Deploy-gate Test-RunnerRegistered PASSED.' }
    else { Write-LogWarn 'Deploy-gate Test-RunnerRegistered reported issues -- inspect the log.' }
}

Set-PhaseMarker $Script:FirstBootMarker
Write-Log '========== FIRST-BOOT REGISTRATION COMPLETE -- RUNNER OPERATIONAL =========='
