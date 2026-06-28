<#
.SYNOPSIS
    Derive the released golden-image version (2.x.y+<gitsha>) from the Packer
    build manifest -- emitted by the build, NOT hand-edited.

.DESCRIPTION
    Closes the version-label gap (VERSION vs GoldenImageVersion vs bootstrap):
    the build manifest is the single source of truth. Reads the base
    version from the repo VERSION file, appends +<gitsha>, and writes a release
    manifest next to the Packer manifest. Run in the CI `promote` stage.

.PARAMETER ManifestPath  Packer build manifest (packer/golden/manifest.json).
.PARAMETER GitSha        Short git SHA of the built commit ($CI_COMMIT_SHORT_SHA).
.PARAMETER VersionFile   Repo VERSION file (base 2.x.y). Default: ./VERSION.
.PARAMETER OutPath       Release manifest output. Default: beside the build manifest.

.NOTES
    File: ci/Publish-GoldenManifest.ps1
    PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$GitSha,
    [string]$VersionFile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'VERSION'),
    [string]$OutPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ManifestPath)) { Write-Error "Build manifest not found: $ManifestPath"; exit 1 }
if (-not (Test-Path $VersionFile))  { Write-Error "VERSION file not found: $VersionFile"; exit 1 }

$baseVersion = (Get-Content $VersionFile -Raw).Trim()
$release     = "$baseVersion+$GitSha"

$buildManifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
# Packer manifest: last build entry carries artifact_id (the template name/uuid).
$lastBuild = @($buildManifest.builds)[-1]

$out = [ordered]@{
    version       = $release
    base_version  = $baseVersion
    git_sha       = $GitSha
    artifact_id   = $lastBuild.artifact_id
    builder_type  = $lastBuild.builder_type
    packer_run_id = $buildManifest.last_run_uuid
}

if (-not $OutPath) { $OutPath = Join-Path (Split-Path $ManifestPath -Parent) 'release-manifest.json' }
($out | ConvertTo-Json -Depth 4) | Out-File -FilePath $OutPath -Encoding UTF8 -Force

Write-Host "Released golden image version: $release"
Write-Host "  artifact: $($lastBuild.artifact_id)"
Write-Host "  manifest: $OutPath"
