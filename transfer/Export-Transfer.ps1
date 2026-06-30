<#
.SYNOPSIS
    Export a versioned air-gap transfer bundle: code (git bundle) + LFS binaries
    (content-addressable store) + a manifest. Run on the staging/internet leg.

.DESCRIPTION
    The bridge to the air-gapped Kayhut network. Code travels as a git bundle;
    binaries travel as the Git LFS content-addressable store (CAS) so LFS-tracked
    blobs resolve on the internal mirror without internet. A manifest records the
    git SHA, the bundle filename, and the LFS object IDs so Import-Transfer can
    verify the hand-off.

    Output layout (under -OutDir):
      <id>/
        <id>.bundle          git bundle of -Ref (all history reachable)
        lfs/objects/...      copied .git/lfs/objects CAS (LFS blobs)
        manifest.json        id, ref, sha, bundle, lfsObjects[], createdUtc

    The transfer is tagged 'transfer/<id>' in the repo so the exact hand-off is
    reproducible.

.PARAMETER OutDir
    Directory to write the transfer folder into. Created if absent.

.PARAMETER Ref
    Git ref to bundle (branch/tag/SHA). Default: current branch.

.PARAMETER Id
    Transfer identifier (folder + tag name). Default: <ref>-<shortsha>-<yyyyMMddHHmmss>.
    Provide explicitly for reproducible/scripted runs.

.PARAMETER RepoRoot
    Repo working tree. Default: parent of this script's directory.

.NOTES
    File: transfer/Export-Transfer.ps1
    PowerShell 5.1. Requires git + git-lfs on PATH. Never commits real binaries to
    the public repo -- this only PACKAGES already-committed LFS objects for USB.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Ref,
    [string]$Id,
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$TimeStamp
)

$ErrorActionPreference = 'Stop'

function Invoke-Git {
    # Returns git's combined output as a single STRING (never an array), so
    # callers can safely .Trim() it. $LASTEXITCODE is read immediately after the
    # native call -- never across a later function boundary (PS 5.1 staleness).
    param([Parameter(Mandatory)][string[]]$GitArgs, [switch]$AllowFail)
    # PS 5.1: `& native 2>&1` under $ErrorActionPreference='Stop' promotes git's
    # normal stderr (e.g. 'Enumerating objects' on bundle create) to a TERMINATING
    # NativeCommandError before $LASTEXITCODE can be read. Force Continue for the
    # native call so we judge success by the exit code, not by stderr presence.
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $raw  = & git -C $RepoRoot @GitArgs 2>&1
    $code = $LASTEXITCODE
    $text = (@($raw) | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0 -and -not $AllowFail) {
        throw "git $($GitArgs -join ' ') failed ($code): $text"
    }
    return $text
}

function Get-GitValue {
    # For value reads (rev-parse): take the last non-empty line, so a stray
    # stderr/hint line merged by 2>&1 can't corrupt the captured SHA/ref.
    param([Parameter(Mandatory)][string[]]$GitArgs)
    $text = Invoke-Git -GitArgs $GitArgs
    return (($text -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim()
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git not found on PATH.' }
if (-not (Test-Path (Join-Path $RepoRoot '.git'))) { throw "Not a git repo: $RepoRoot" }

# Resolve ref + sha
if (-not $Ref) { $Ref = Get-GitValue @('rev-parse','--abbrev-ref','HEAD') }
$sha      = Get-GitValue @('rev-parse', $Ref)
$shortSha = $sha.Substring(0, 7)

# Caller passes a timestamp (the harness clock); fall back to the local clock.
if (-not $TimeStamp) { $TimeStamp = (Get-Date).ToString('yyyyMMddHHmmss') }
if (-not $Id) { $Id = "$($Ref -replace '[\\/]','-')-$shortSha-$TimeStamp" }

$dest = Join-Path $OutDir $Id
if (Test-Path $dest) { throw "Transfer folder already exists: $dest" }
New-Item -ItemType Directory -Path $dest -Force | Out-Null

# 1. Git bundle (full history reachable from the ref)
$bundleName = "$Id.bundle"
$bundlePath = Join-Path $dest $bundleName
Write-Host "Bundling $Ref ($shortSha) -> $bundlePath"
Invoke-Git @('bundle','create', $bundlePath, $Ref) | Out-Null

# 2. Copy the LFS CAS so binary blobs travel with the bundle. Copy runs under
#    $ErrorActionPreference='Stop' and is verified by object count -- a partial
#    CAS copy must fail loudly, never ship a half-empty binary hand-off.
$lfsSrc = Join-Path $RepoRoot '.git\lfs\objects'
$lfsObjects = @()
$srcFiles = @()
if (Test-Path $lfsSrc) { $srcFiles = @(Get-ChildItem -Path $lfsSrc -Recurse -File -ErrorAction SilentlyContinue) }
if ($srcFiles.Count -gt 0) {
    $lfsDst = Join-Path $dest 'lfs\objects'
    New-Item -ItemType Directory -Path $lfsDst -Force | Out-Null
    Copy-Item -Path (Join-Path $lfsSrc '*') -Destination $lfsDst -Recurse -Force
    $lfsObjects = @(Get-ChildItem -Path $lfsDst -Recurse -File | ForEach-Object { $_.Name })
    if ($lfsObjects.Count -ne $srcFiles.Count) {
        throw "LFS CAS copy incomplete: $($srcFiles.Count) source object(s), $($lfsObjects.Count) copied."
    }
    Write-Host "Copied $($lfsObjects.Count) LFS object(s) into $lfsDst"
} else {
    Write-Host 'No .git/lfs/objects present -- bundle carries no LFS binaries (expected on the public dev leg).'
}

# 3. Tag the exact hand-off (idempotent: replace an existing same-id tag)
Invoke-Git @('tag','-f', "transfer/$Id", $sha) | Out-Null

# 4. Manifest
$manifest = [ordered]@{
    id         = $Id
    ref        = $Ref
    sha        = $sha
    bundle     = $bundleName
    lfsObjects = $lfsObjects
    createdUtc = $TimeStamp
}
$manifestPath = Join-Path $dest 'manifest.json'
($manifest | ConvertTo-Json -Depth 4) | Out-File -FilePath $manifestPath -Encoding UTF8 -Force

Write-Host ''
Write-Host "Transfer ready: $dest"
Write-Host "  ref=$Ref sha=$shortSha tag=transfer/$Id lfsObjects=$($lfsObjects.Count)"
Write-Host '  Copy this folder to USB and run transfer/Import-Transfer.ps1 on the internal leg.'
