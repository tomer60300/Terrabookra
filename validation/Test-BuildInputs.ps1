<#
.SYNOPSIS
    Build-input pre-flight for the Packer model: confirm the artifacts the build
    consumes are present in the uploaded repo tree (Git LFS materialized) and that
    the GitLab host + Container Registry are reachable. Replaces the MinIO/Harbor
    Test-Dependencies.ps1 pre-flight (MinIO retired, images now from GitLab).

.DESCRIPTION
    Run as Phase 1 step 1.0 (build-time pre-flight) and by the CI `validate`
    stage. Two independent checks:
      [1] Inputs  -- every artifact path in the Config catalogs (S3Keys,
                     S3KeysExtra, ToolPackages[].S3Key, ObservabilityPackages,
                     S3Certs) resolves to an existing file under the repo root.
                     Catches an LFS object that did not materialize.
      [2] Registry-- DNS + TCP reachability of the GitLab host (:443) and the
                     GitLab Container Registry (host:port). No pull, just reach.

    Exits non-zero if any enabled check fails.

.PARAMETER SkipInputs    Skip the artifact-presence check.
.PARAMETER SkipRegistry  Skip the GitLab/registry reachability check.

.NOTES
    File: validation/Test-BuildInputs.ps1
    Requires: lib/Config.ps1 + lib/Common.ps1 (Get-RepoPath). Dot-sources them if
    $Script:Config / Get-RepoPath are not already available.
#>
param(
    [switch]$SkipInputs,
    [switch]$SkipRegistry
)

$ErrorActionPreference = 'Continue'

# --- Load Config + Common if not already present -----------------------------
if (-not $Script:Config -or -not (Get-Command Get-RepoPath -ErrorAction SilentlyContinue)) {
    $root = $PSScriptRoot
    if (-not (Test-Path (Join-Path $root 'lib\Config.ps1'))) { $root = Split-Path $PSScriptRoot -Parent }
    $libDir = Join-Path $root 'lib'
    if (-not (Test-Path (Join-Path $libDir 'Config.ps1'))) {
        Write-Host '[FATAL] Cannot find lib\Config.ps1' -ForegroundColor Red; exit 1
    }
    if (-not $Script:Config) { . (Join-Path $libDir 'Config.ps1') }
    if (-not (Get-Command Get-RepoPath -ErrorAction SilentlyContinue)) { . (Join-Path $libDir 'Common.ps1') }
}

$fail = 0
function Note { param([string]$Msg, [bool]$Ok) Write-Host ("  [{0}] {1}" -f $(if ($Ok) {'PASS'} else {'FAIL'}), $Msg); if (-not $Ok) { $script:fail++ } }

Write-Host '============================================'
Write-Host 'Test-BuildInputs -- repo artifacts + GitLab registry reachability'
Write-Host '============================================'

# --- [1] Artifact presence in the uploaded repo tree -------------------------
if (-not $SkipInputs) {
    Write-Host '[1] Build inputs present in repo (Git LFS materialized)'
    $relPaths = New-Object System.Collections.Generic.List[string]
    foreach ($v in $Script:Config.S3Keys.Values)      { [void]$relPaths.Add($v) }
    foreach ($v in $Script:Config.S3KeysExtra.Values)  { [void]$relPaths.Add($v) }
    foreach ($t in $Script:Config.ToolPackages)        { if ($t.S3Key) { [void]$relPaths.Add($t.S3Key) } }
    foreach ($t in $Script:Config.ToolPackages)        { if ($t.Dependencies) { foreach ($d in $t.Dependencies) { [void]$relPaths.Add($d) } } }
    if ($Script:Config.ObservabilityPackages.WindowsExporter.S3Key)  { [void]$relPaths.Add($Script:Config.ObservabilityPackages.WindowsExporter.S3Key) }
    if ($Script:Config.ObservabilityPackages.BlackboxExporter.S3Key) { [void]$relPaths.Add($Script:Config.ObservabilityPackages.BlackboxExporter.S3Key) }
    foreach ($c in $Script:Config.S3Certs)             { [void]$relPaths.Add($c) }

    # The S3Bootstrap table is the legacy Be1 self-fetch -- not a build input.
    foreach ($rel in ($relPaths | Sort-Object -Unique)) {
        $abs = Get-RepoPath $rel
        Note "$rel" (Test-Path $abs)
    }
}

# --- [2] GitLab host + Container Registry reachability -----------------------
if (-not $SkipRegistry) {
    Write-Host '[2] GitLab + registry reachability (DNS + TCP)'
    $gitLabHost = ([System.Uri]$Script:Config.GitLabUrl).Host
    $reg        = $Script:Config.GitLabRegistry
    $regHost    = ($reg -split ':')[0]
    $regPort    = if ($reg -match ':(\d+)$') { [int]$Matches[1] } else { 443 }

    foreach ($probe in @(
        @{ Host = $gitLabHost; Port = 443 },
        @{ Host = $regHost;    Port = $regPort }
    )) {
        $ok = $false
        try {
            [void][System.Net.Dns]::GetHostAddresses($probe.Host)
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ar  = $tcp.BeginConnect($probe.Host, $probe.Port, $null, $null)
            $ok  = $ar.AsyncWaitHandle.WaitOne(3000) -and $tcp.Connected
            $tcp.Close()
        } catch { $ok = $false }
        Note ("{0}:{1}" -f $probe.Host, $probe.Port) $ok
    }
}

Write-Host '============================================'
if ($fail -gt 0) {
    Write-Host "FAILED: $fail build-input check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'PASSED: all build inputs present and registry reachable.'
exit 0
