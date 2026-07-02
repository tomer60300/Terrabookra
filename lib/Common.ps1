<#
.SYNOPSIS
    Common helpers -- TLS bypass, logging, local artifact source, PE validation,
    phase markers.

.DESCRIPTION
    Dot-sourced after Config.ps1 (by provisioners/Invoke-Phase.ps1 in the Packer
    model). Provides the shared functions used across phases.

.NOTES
    File: lib/Common.ps1
    Used by: provisioners/Invoke-Phase.ps1, phases/*.ps1, validation/*.ps1

    Functions exported:
      Write-Log, Write-LogError, Write-LogWarn
      Get-RepoPath, Copy-RepoFile, Install-LocalBinary, Install-LocalArchive
      Test-PEBinary
      Wait-ServiceRunning
      Get-DnsServer
      Set-PhaseMarker, Test-PhaseComplete
#>

# ============================================================
# TLS BYPASS -- Guard against re-add on repeated runs
# ============================================================

if (-not ([System.Management.Automation.PSTypeName]'TrustAllCerts').Type) {
    Add-Type -TypeDefinition @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts {
    public static void Enable() {
        ServicePointManager.ServerCertificateValidationCallback =
            delegate { return true; };
        ServicePointManager.SecurityProtocol =
            SecurityProtocolType.Tls12 | SecurityProtocolType.Tls11 | SecurityProtocolType.Tls;
    }
}
"@
}

[TrustAllCerts]::Enable()

# ============================================================
# LOGGING
# ============================================================

$Script:LogFile = 'C:\GitLab-Runner\logs\install.log'

# Correlation ID for this invocation (build phase vs first-boot are separable in
# the shared log) and a component tag the entry script sets (e.g. 'phase1',
# 'phase3-install', 'firstboot'). Entry scripts may set $Script:Component before
# logging; both have safe defaults so existing callers are unaffected.
if (-not $Script:RunId)     { $Script:RunId = [guid]::NewGuid().ToString('N').Substring(0, 8) }
if (-not $Script:Component) { $Script:Component = 'runner' }

function Write-Log {
    <#
    .SYNOPSIS  Write a timestamped, tagged line to the install log and stdout.
               Format: [ts] [LEVEL] [component] [runid] message
    #>
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] [$Script:Component] [$Script:RunId] $Message"
    $dir  = Split-Path $Script:LogFile -Parent
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $line | Out-File -FilePath $Script:LogFile -Append -Encoding UTF8
    # [Console]::WriteLine, NOT Write-Output: Write-Output emits to the success
    # stream, so any boolean-returning function that logs (Copy-RepoFile,
    # Install-Local*, Invoke-Registration, Test-AlreadyRegistered, ...) would
    # return @('<log line>', $bool) -- an ARRAY that is always truthy, making
    # `if (-not (helper))` fail OPEN on errors. WriteLine reaches stdout (Packer/CI
    # capture it) without polluting the pipeline.
    [Console]::WriteLine($line)
}

function Write-LogError { param([string]$Message) Write-Log -Message $Message -Level 'ERROR' }
function Write-LogWarn  { param([string]$Message) Write-Log -Message $Message -Level 'WARN'  }

# ============================================================
# LOCAL ARTIFACT SOURCE (Packer model -- repo is uploaded into the guest)
# ============================================================
# There is no MinIO fetch: Packer's `file` provisioner uploads the whole repo
# into the guest, so artifacts are read from the uploaded tree. $Script:RepoRoot
# is the parent of this lib/ directory, so it resolves wherever Packer placed the
# repo. The artifact catalogs in Config.ps1 (S3Keys / S3KeysExtra /
# ToolPackages[].S3Key / ObservabilityPackages) carry repo-relative paths (e.g.
# 'binaries/git/MinGit-2.43.0-64-bit.zip'); these helpers consume them locally.
# (The MinIO SigV4 Get-S3Object was removed with the Be1 retirement.)

# $PSScriptRoot = this lib/ dir when dot-sourced from a path; parent = repo root.
# Fall back to $PSCommandPath, then the legacy bootstrap dir, if it is empty
# (e.g. loaded via Invoke-Expression on content rather than from a file path).
$Script:RepoRoot =
    if     ($PSScriptRoot)   { Split-Path $PSScriptRoot -Parent }
    elseif ($PSCommandPath)  { Split-Path (Split-Path $PSCommandPath -Parent) -Parent }
    else                     { 'C:\GitLab-Runner' }

function Get-RepoPath {
    <#
    .SYNOPSIS  Resolve a repo-relative artifact path against the uploaded repo root.
    #>
    param([Parameter(Mandatory)][string]$RelPath)
    # Catalog paths use '/'. Normalize to the platform separator (on Windows that
    # is '\'; staying platform-correct also keeps the helper testable off-Windows).
    return (Join-Path $Script:RepoRoot ($RelPath -replace '/', [System.IO.Path]::DirectorySeparatorChar))
}

function Copy-RepoFile {
    <#
    .SYNOPSIS  Copy an artifact from the uploaded repo tree to a destination.
    .OUTPUTS   [bool] $true on success. Signature mirrors the old artifact
               helper enough that call sites remain easy to audit.
    #>
    param(
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)][string]$OutFile
    )
    $src = Get-RepoPath $RelPath
    if (-not (Test-Path $src)) { Write-LogError "Artifact not found in repo: $src"; return $false }
    $outDir = Split-Path $OutFile -Parent
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -Path $outDir -ItemType Directory -Force | Out-Null }
    Copy-Item -Path $src -Destination $OutFile -Force
    if (Test-Path $OutFile) {
        Write-Log "Copied $RelPath -> $OutFile ($((Get-Item $OutFile).Length) bytes)"
        return $true
    }
    Write-LogError "Copy produced no file: $OutFile"
    return $false
}

# ============================================================
# BINARY HELPERS
# ============================================================

function Install-LocalBinary {
    <#
    .SYNOPSIS  Copy an EXE from the uploaded repo and validate its PE header.
    .NOTES     Skip-if-exists: safe because the source (Packer-uploaded repo) is
               immutable per build. Do NOT reuse for rotation-prone artifacts
               (CA certs / bootstrap files) -- use Copy-RepoFile (always re-copies).
    #>
    param([string]$RelPath, [string]$DestPath, [string]$Label)
    if (Test-PEBinary $DestPath) { Write-Log "$Label already present"; return $true }
    if ((Copy-RepoFile -RelPath $RelPath -OutFile $DestPath) -and (Test-PEBinary $DestPath)) {
        Write-Log "$Label copied and validated"; return $true
    }
    Write-LogError "FATAL: $Label -- copy or PE validation failed"
    return $false
}

function Install-LocalArchive {
    <#
    .SYNOPSIS  Extract a ZIP from the uploaded repo.
    #>
    param([string]$RelPath, [string]$DestDir, [string]$TestFile, [string]$Label)
    if ($TestFile -and (Test-Path $TestFile)) { Write-Log "$Label already present"; return $true }
    $src = Get-RepoPath $RelPath
    if (-not (Test-Path $src)) { Write-LogError "FATAL: $Label -- archive not found: $src"; return $false }
    Expand-Archive -Path $src -DestinationPath $DestDir -Force
    Write-Log "$Label extracted to $DestDir"
    return $true
}

function Test-PEBinary {
    <#
    .SYNOPSIS  Validate that a file has a valid PE (MZ) header.
    #>
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        return ($bytes.Length -ge 2 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A)
    }
    catch {
        Write-LogWarn "PE validation failed for $Path : $_"
        return $false
    }
}

# (Install-S3Binary / Install-S3Archive removed with the Be1 retirement --
#  Install-LocalBinary / Install-LocalArchive above are their replacements.)

# ============================================================
# SERVICE HELPERS
# ============================================================

function Wait-ServiceRunning {
    <#
    .SYNOPSIS  Poll until a Windows service is running (or timeout).
    #>
    param([string]$Name, [int]$TimeoutSeconds = 120, [int]$PollSeconds = 10, [switch]$StartIfStopped)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { return $true }
        if ($StartIfStopped -and $svc -and $svc.Status -ne 'Running') {
            Start-Service -Name $Name -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds $PollSeconds
    }
    return $false
}

function Get-DnsServer {
    <#
    .SYNOPSIS  Return up to 2 DNS server addresses from active adapters.
    .NOTES     Wraps result in @() to prevent PS 5.1 from unwrapping a single
               string into a char array when indexed with [0].
    #>
    $servers = @()
    try {
        $adapters = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.ServerAddresses.Count -gt 0 }
        foreach ($a in $adapters) { $servers += $a.ServerAddresses }
        $servers = @($servers | Select-Object -Unique | Select-Object -First 2)
    }
    catch { Write-LogWarn "DNS auto-detect failed: $_" }
    return , $servers
}

# ============================================================
# PHASE MARKERS
# ============================================================
# (Invoke-Be1Reboot removed with the Be1 retirement -- Packer owns reboots via
#  the windows-restart provisioner between phases.)

function Set-PhaseMarker {
    <#
    .SYNOPSIS  Write a timestamp marker file indicating a phase completed.
    #>
    param([string]$Path)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    Get-Date -Format 'o' | Out-File -FilePath $Path -Encoding UTF8 -Force
    Write-Log "Phase marker set: $Path"
}

function Test-PhaseComplete {
    <#
    .SYNOPSIS  Return $true iff a phase-completion marker exists.
    .DESCRIPTION
        Completion markers are DURABLE and never expire. A phase writes its
        marker only after fully succeeding, so the marker's presence is a
        permanent "this phase is done" fact. There is no mid-phase marker, so a
        crash before completion leaves no marker and the phase re-runs on the
        next boot naturally -- no time-based staleness needed. (A prior version
        deleted markers older than StaleMinutes, which could wrongly re-run a
        completed phase on an old golden image or restored snapshot.)
    #>
    param([string]$Path)
    return (Test-Path $Path)
}
