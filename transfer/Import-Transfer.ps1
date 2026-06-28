<#
.SYNOPSIS
    Import a transfer bundle produced by Export-Transfer.ps1 into an internal repo:
    restore the LFS CAS, fetch from the bundle, and materialize the working tree.
    Run on the air-gapped internal leg.

.DESCRIPTION
    Reverse of Export-Transfer.ps1:
      1. Read manifest.json (id, ref, sha, bundle, lfsObjects).
      2. Restore the LFS content-addressable store into .git/lfs/objects so
         LFS-tracked binaries resolve locally (no internet / no LFS server).
      3. git fetch the bundle (brings the ref + history), then verify the fetched
         tip SHA matches the manifest.
      4. Check out / update the target branch and run `git lfs checkout` to
         materialize binary working-tree files from the restored CAS.

.PARAMETER InDir
    The transfer folder (the '<id>' directory written by Export-Transfer.ps1).

.PARAMETER RepoRoot
    Target internal repo working tree. Default: parent of this script's directory.

.PARAMETER Branch
    Local branch to update to the imported ref. Default: the manifest 'ref' when it
    looks like a branch name, else 'main'.

.PARAMETER NoCheckout
    Fetch + restore LFS only; do not move the working tree (for inspection).

.NOTES
    File: transfer/Import-Transfer.ps1
    PowerShell 5.1. Requires git + git-lfs on PATH.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InDir,
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$Branch,
    [switch]$NoCheckout
)

$ErrorActionPreference = 'Stop'

function Invoke-Git {
    # Returns git's combined output as a single STRING (never an array), so
    # callers can safely .Trim() it. $LASTEXITCODE is read immediately after the
    # native call -- never across a later function boundary (PS 5.1 staleness).
    param([Parameter(Mandatory)][string[]]$GitArgs, [switch]$AllowFail)
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

function Test-GitRef {
    # Boolean ref-existence test. Reads $LASTEXITCODE immediately after the native
    # call (inside the function) -- the correct PS 5.1 pattern.
    param([Parameter(Mandatory)][string]$RefName)
    $global:LASTEXITCODE = 0
    & git -C $RepoRoot rev-parse --verify --quiet $RefName 1>$null 2>$null
    return ($LASTEXITCODE -eq 0)
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git not found on PATH.' }
if (-not (Test-Path (Join-Path $RepoRoot '.git'))) { throw "Not a git repo: $RepoRoot" }

$manifestPath = Join-Path $InDir 'manifest.json'
if (-not (Test-Path $manifestPath)) { throw "manifest.json not found in $InDir" }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

$bundlePath = Join-Path $InDir $manifest.bundle
if (-not (Test-Path $bundlePath)) { throw "Bundle not found: $bundlePath" }

Write-Host "Importing transfer '$($manifest.id)' (ref=$($manifest.ref) sha=$($manifest.sha.Substring(0,7)))"

# 1. Restore the LFS CAS first, so checkout can resolve binaries offline. The
#    copy runs under Stop and is verified against the manifest -- a missing blob
#    must fail here, not silently surface as an empty file after checkout.
$manifestObjects = @($manifest.lfsObjects)
$lfsSrc = Join-Path $InDir 'lfs\objects'
if (Test-Path $lfsSrc) {
    $lfsDst = Join-Path $RepoRoot '.git\lfs\objects'
    New-Item -ItemType Directory -Path $lfsDst -Force | Out-Null
    Copy-Item -Path (Join-Path $lfsSrc '*') -Destination $lfsDst -Recurse -Force
    $haveNames = @(Get-ChildItem -Path $lfsDst -Recurse -File | ForEach-Object { $_.Name })
    $missing = @($manifestObjects | Where-Object { $haveNames -notcontains $_ })
    if ($missing.Count -gt 0) { throw "Restored LFS CAS is missing $($missing.Count) object(s) named in the manifest." }
    Write-Host "Restored $($haveNames.Count) LFS object(s) into $lfsDst"
} elseif ($manifestObjects.Count -gt 0) {
    throw "Manifest declares $($manifestObjects.Count) LFS object(s) but the transfer carries no lfs/objects directory."
} else {
    Write-Host 'Transfer carries no LFS objects -- code-only import.'
}

# 2. Fetch the ref from the bundle into a tracking ref, then verify the tip SHA.
$importRef = "refs/transfer/$($manifest.id)"
Invoke-Git @('fetch', $bundlePath, "$($manifest.ref):$importRef") | Out-Null
$fetched = Get-GitValue @('rev-parse', $importRef)
if ($fetched -ne $manifest.sha) {
    throw "Imported tip $fetched does not match manifest sha $($manifest.sha) -- aborting."
}
Write-Host "Bundle fetched and SHA-verified ($($fetched.Substring(0,7)))."

if ($NoCheckout) {
    Write-Host "Fetched to $importRef (no checkout). LFS CAS restored. Done."
    return
}

# 3. Move the target branch to the imported tip and materialize the working tree.
if (-not $Branch) {
    $Branch = if ($manifest.ref -match '^[\w./-]+$' -and $manifest.ref -notmatch '^[0-9a-f]{7,40}$') { $manifest.ref } else { 'main' }
}
if (Test-GitRef "refs/heads/$Branch") {
    Invoke-Git @('checkout', $Branch) | Out-Null
    Invoke-Git @('merge','--ff-only', $importRef) | Out-Null
} else {
    Invoke-Git @('checkout','-b', $Branch, $importRef) | Out-Null
}

# 4. Materialize LFS binaries from the restored CAS.
if (Get-Command git-lfs -ErrorAction SilentlyContinue) {
    Invoke-Git @('lfs','checkout') -AllowFail | Out-Null
    Write-Host 'git lfs checkout complete.'
} else {
    Write-Host 'git-lfs not on PATH -- skipped binary checkout (install git-lfs to materialize LFS files).'
}

Write-Host ''
Write-Host "Import complete: branch '$Branch' at $($manifest.sha.Substring(0,7))."
