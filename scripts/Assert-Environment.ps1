<#
.SYNOPSIS
    Fail-fast environment preflight. Asserts every precondition the bootstrap
    flow CONSUMES but does not itself create, so an unknown VM fails loudly and
    early instead of cryptically and deep. See docs/VALIDATION.md.

.DESCRIPTION
    Run this as the very first step of provisioning -- ideally from
    Bootstrap-GitLabRunner.ps1 right after Config.ps1 + Common.ps1 are fetched
    (Phase 0), or at the top of Phase1-SystemPrep.ps1 before step 1.0. It is
    additive and standalone: it does not modify the flow's logic.

    Checks (HARD = aborts with exit 1; WARN = surfaced, non-fatal unless -Strict):
      [HARD] Running as Administrator
      [HARD] PowerShell major version >= 5
      [WARN] Windows Server edition + build 17763 (LTSC 2019 -- the pinned target)
      [HARD] .NET ZipFile type available (zip extraction is load-bearing)
      [HARD] Config.ps1 loads and $Script:Config is populated
      [HARD] GitLab URL / registry / registry-project are set (MinIO is retired)
      [HARD] GitLab URL is a parseable absolute URL
      [WARN] GITLAB_RUNNER_TOKEN present (Phase 3 hard-checks it later)
      [HARD] Data drive resolves to a FIXED NTFS volume (not DVD/USB)
      [HARD] Core directories are creatable (RunnerDir, LogsDir)
      [FIX ] Event-log source 'GitLabRunner' exists (created here if missing)
      [WARN] GitLab endpoint host:port is TCP-reachable

    The event-log source check is the one that also *fixes*: it registers the
    source if absent so every later Write-EventLog (watchdogs, disk-monitor,
    validation) can't throw on a host where Phase 1 hasn't run yet.

.PARAMETER ConfigPath  Explicit path to lib/Config.ps1. Auto-located if omitted.
.PARAMETER Strict      Treat WARN as failure (exit 1).
.PARAMETER ExpectedBuild  OS build to expect. Default 17763 (Server 2019 LTSC).

.NOTES
    File: scripts/Assert-Environment.ps1  (suggested location)
    Run as: Administrator. PowerShell 5.1. Air-gapped safe (no internet).
    Exit: 0 = all hard checks passed; 1 = at least one hard failure (or any WARN under -Strict).
#>

param(
    [string]$ConfigPath,
    [switch]$Strict,
    [int]$ExpectedBuild = 17763
)

$ErrorActionPreference = 'Continue'

$script:Fails = 0
$script:Warns = 0

function Write-Check {
    param([ValidateSet('PASS','WARN','FAIL','FIX')][string]$State, [string]$Message)
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Output ("[{0}] [{1,-4}] {2}" -f $ts, $State, $Message)
    if ($State -eq 'FAIL') { $script:Fails++ }
    if ($State -eq 'WARN') { $script:Warns++ }
}

Write-Output '========== Assert-Environment (preflight) =========='

# --- Administrator -----------------------------------------------------------
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) { Write-Check PASS 'Running as Administrator' }
    else          { Write-Check FAIL 'NOT running as Administrator -- bootstrap requires elevation' }
} catch { Write-Check FAIL "Admin check failed: $($_.Exception.Message)" }

# --- PowerShell version ------------------------------------------------------
$psMajor = $PSVersionTable.PSVersion.Major
if ($psMajor -ge 5) { Write-Check PASS "PowerShell $($PSVersionTable.PSVersion) (>= 5)" }
else                { Write-Check FAIL "PowerShell $($PSVersionTable.PSVersion) -- 5.1 required (uses 5.1-only cmdlets)" }

# --- OS edition + build ------------------------------------------------------
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $build = [int]([Environment]::OSVersion.Version.Build)
    # ProductType: 1 = workstation, 2 = domain controller, 3 = server
    if ($os.ProductType -eq 1) {
        Write-Check WARN "OS is a workstation SKU ('$($os.Caption)') -- Containers/Hyper-V features expect Server"
    }
    if ($build -eq $ExpectedBuild) {
        Write-Check PASS "OS build $build ('$($os.Caption)')"
    } else {
        Write-Check WARN "OS build $build != expected $ExpectedBuild -- artifacts are pinned to Server 2019 LTSC; verify images/tools match"
    }
} catch { Write-Check WARN "Could not read OS info: $($_.Exception.Message)" }

# --- .NET ZipFile (zip extraction is load-bearing) ---------------------------
try {
    # Load the assembly the SAME way the extraction code does (Install-Tools,
    # Enable-RemoteSSH, Install-Observability). -ErrorAction Stop so a genuine
    # load failure is reported here instead of being masked.
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    # Resolve via PowerShell's own type system (searches loaded assemblies).
    # The old [Type]::GetType('...,System.IO.Compression.FileSystem') probe used
    # a PARTIAL assembly name and returned $null on WS2019 even though the type
    # is fully usable -- a false-positive HARD failure that aborted the run.
    if ('System.IO.Compression.ZipFile' -as [type]) {
        Write-Check PASS '.NET System.IO.Compression.ZipFile available'
    } else {
        Write-Check FAIL '.NET ZipFile type unavailable after loading assembly -- zip extraction (Docker/tools) will fail'
    }
} catch { Write-Check FAIL ".NET ZipFile assembly failed to load: $($_.Exception.Message)" }

# --- Locate + load Config ----------------------------------------------------
if (-not $Script:Config) {
    if (-not $ConfigPath) {
        $candidates = @(
            (Join-Path $PSScriptRoot '..\lib\Config.ps1'),
            (Join-Path $PSScriptRoot '..\bootstrap\lib\Config.ps1'),
            'C:\GitLab-Runner\lib\Config.ps1',
            'C:\Bootstrap\lib\Config.ps1'
        )
        $ConfigPath = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    }
    if ($ConfigPath -and (Test-Path $ConfigPath)) {
        try { . $ConfigPath } catch { Write-Check FAIL "Config.ps1 failed to load: $($_.Exception.Message)" }
    }
}
if ($Script:Config) { Write-Check PASS "Config loaded (version $($Script:Config.GoldenImageVersion))" }
else                { Write-Check FAIL 'Config.ps1 not found / $Script:Config empty -- cannot validate settings' }

# --- Config: GitLab + container registry settings ----------------------------
# MinIO is retired; images come from the GitLab Container Registry.
if ($Script:Config) {
    foreach ($f in @('GitLabUrl','GitLabRegistry','RegistryProject')) {
        if ([string]::IsNullOrWhiteSpace([string]$Script:Config.$f)) { Write-Check FAIL "Config.$f is empty" }
        else { Write-Check PASS "Config.$f set ($($Script:Config.$f))" }
    }

    # GitLab URL parseable
    $gl = [string]$Script:Config.GitLabUrl
    $parsed = $null
    if (-not [string]::IsNullOrWhiteSpace($gl) -and [Uri]::TryCreate($gl, [UriKind]::Absolute, [ref]$parsed)) {
        Write-Check PASS "GitLab URL parseable ($gl)"
    } else {
        Write-Check FAIL "GitLab URL missing/invalid: '$gl'"
    }

    # Registry creds are env-injected at build time (REAL_GITLAB_REGISTRY_USER/PASS)
    # and MAY be empty (anonymous pull). Warn, do not fail.
    if ([string]::IsNullOrWhiteSpace([string]$Script:Config.GitLabRegistryUser) -or
        [string]::IsNullOrWhiteSpace([string]$Script:Config.GitLabRegistryPass)) {
        Write-Check WARN 'GitLab registry creds unset (REAL_GITLAB_REGISTRY_USER/PASS) -- anonymous pull assumed; private images will fail.'
    } else {
        Write-Check PASS 'GitLab registry credentials present (env-injected)'
    }
}

# --- Runner token: first-boot concern, NOT a build requirement ----------------
# The image ships UNREGISTERED; the token arrives per-clone via vSphere guestinfo
# at first boot (Register-RunnerFirstBoot.ps1), so it is not needed during build.
Write-Check PASS 'Runner token not required at build time (delivered via guestinfo at first boot)'

# --- Data drive: must be a FIXED NTFS volume ---------------------------------
$dataDrive = if ($Script:Config -and $Script:Config.ContainsKey('BuildsDir') -and $Script:Config.BuildsDir) {
    ([string]$Script:Config.BuildsDir).Substring(0,1)
} elseif (Test-Path 'E:\') { 'E' } else { 'C' }
try {
    $vol = Get-Volume -DriveLetter $dataDrive -ErrorAction Stop
    $dt  = [string]$vol.DriveType
    # Positive assertion: only an explicit 'Fixed' passes. Removable/CD-ROM hard-fail.
    # An unknown/empty DriveType (some iSCSI/Storage-Spaces volumes) is a WARN, never
    # a silent pass -- the old code defaulted $isFixed=$true and failed open.
    if ($dt -eq 'Fixed') {
        if ($vol.FileSystemType -and $vol.FileSystemType -ne 'NTFS') {
            Write-Check FAIL "Data drive ${dataDrive}: is $($vol.FileSystemType) -- must be NTFS"
        } else {
            $freeGB = [math]::Round($vol.SizeRemaining / 1GB, 1)
            Write-Check PASS "Data drive ${dataDrive}: Fixed/NTFS, ${freeGB}GB free"
        }
    } elseif ($dt -in @('Removable','CD-ROM')) {
        Write-Check FAIL "Data drive ${dataDrive}: is '$dt' (removable) -- refuse as docker data-root"
    } else {
        Write-Check WARN "Data drive ${dataDrive}: DriveType '$dt' undetermined -- verify it is a fixed NTFS disk before relying on it"
    }
} catch {
    Write-Check FAIL "Data drive ${dataDrive}: not present/queryable: $($_.Exception.Message)"
}

# --- Core directories creatable ----------------------------------------------
$dirsToTest = @()
if ($Script:Config) { $dirsToTest = @($Script:Config.RunnerDir, $Script:Config.LogsDir) | Where-Object { $_ } }
else { $dirsToTest = @('C:\GitLab-Runner', 'C:\GitLab-Runner\logs') }
foreach ($d in $dirsToTest) {
    try {
        if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        $probe = Join-Path $d ".writeprobe_$([Guid]::NewGuid().ToString('N'))"
        Set-Content -Path $probe -Value 'x' -ErrorAction Stop
        Remove-Item $probe -Force -ErrorAction SilentlyContinue
        Write-Check PASS "Directory writable: $d"
    } catch { Write-Check FAIL "Cannot create/write directory ${d}: $($_.Exception.Message)" }
}

# --- Event-log source: ensure it exists (create if missing) ------------------
try {
    if ([System.Diagnostics.EventLog]::SourceExists('GitLabRunner')) {
        Write-Check PASS "Event-log source 'GitLabRunner' present"
    } else {
        New-EventLog -LogName Application -Source 'GitLabRunner' -ErrorAction Stop
        Write-Check FIX  "Event-log source 'GitLabRunner' was missing -- created"
    }
} catch { Write-Check WARN "Could not ensure event-log source: $($_.Exception.Message)" }

# --- GitLab endpoint TCP reachability (soft) ---------------------------------
if ($Script:Config -and $parsed) {
    $epHost = $parsed.Host
    $epPort = if ($parsed.Port -gt 0) { $parsed.Port } else { 443 }
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($epHost, $epPort, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(3000) -and $tcp.Connected) {
            Write-Check PASS "GitLab endpoint reachable ($epHost`:$epPort)"
        } else {
            Write-Check WARN "GitLab endpoint ${epHost}:${epPort} not reachable in 3s -- check DNS/hosts/network (Test-BuildInputs probes deeper)"
        }
        $tcp.Close()
    } catch { Write-Check WARN "GitLab endpoint ${epHost}:${epPort} probe error: $($_.Exception.Message)" }
}

# --- Verdict -----------------------------------------------------------------
Write-Output ''
Write-Output ("Preflight: {0} hard failure(s), {1} warning(s)." -f $script:Fails, $script:Warns)
$hardStop = ($script:Fails -gt 0) -or ($Strict -and $script:Warns -gt 0)
if ($hardStop) {
    Write-Output 'RESULT: FAIL -- fix the items above before provisioning.'
    exit 1
}
Write-Output 'RESULT: PASS -- environment satisfies the flow''s preconditions.'
exit 0
