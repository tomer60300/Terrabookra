<#
.SYNOPSIS
    Upload changed repo files to MinIO (S3-compatible) using AWS Signature V4.

.DESCRIPTION
    Pure PowerShell -- no mc.exe, no aws-cli, no external modules.
    Uses the same AWS SigV4 signing pattern as Bootstrap-GitLabRunner.ps1.

    Called by .gitlab-ci.yml with credentials from CI/CD variables.

.PARAMETER Endpoint
    MinIO endpoint URL (e.g. https://minio-host:9000)

.PARAMETER Bucket
    Target S3 bucket name

.PARAMETER AccessKey
    MinIO access key (from CI/CD variable)

.PARAMETER SecretKey
    MinIO secret key (from CI/CD variable)

.PARAMETER Region
    S3 region (default: us-east-1)

.PARAMETER DryRun
    Show what would be uploaded without actually uploading

.NOTES
    File: ci/Sync-ToMinio.ps1
    Requires: PowerShell 5.1+
#>
param(
    [Parameter(Mandatory)][string]$Endpoint,
    [Parameter(Mandatory)][string]$Bucket,
    [Parameter(Mandatory)][string]$AccessKey,
    [Parameter(Mandatory)][string]$SecretKey,
    [string]$Region = 'us-east-1',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ============================================================
# TLS BYPASS (self-signed certs)
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
# FILE MAP -- repo path -> S3 object key
# Single source of truth for what gets synced to MinIO.
# ============================================================

$FileMap = [ordered]@{
    # --- Bootstrap entry point (Be1 fetches this) ---
    'Bootstrap-GitLabRunner.ps1'               = 'Bootstrap-GitLabRunner.ps1'

    # --- lib (Phase 0 downloads these) ---
    'lib/Config.ps1'                           = 'bootstrap/lib/Config.ps1'
    'lib/Common.ps1'                           = 'bootstrap/lib/Common.ps1'

    # --- phases (Phase 0 downloads these) ---
    'phases/Phase1-SystemPrep.ps1'             = 'bootstrap/phases/Phase1-SystemPrep.ps1'
    'phases/Phase2-DockerInstall.ps1'          = 'bootstrap/phases/Phase2-DockerInstall.ps1'
    'phases/Phase3-RunnerSetup.ps1'            = 'bootstrap/phases/Phase3-RunnerSetup.ps1'

    # --- validation ---
    'validation/Invoke-FinalValidation.ps1'    = 'bootstrap/validation/Invoke-FinalValidation.ps1'
    'validation/Test-Dependencies.ps1'         = 'validation/Test-Dependencies.ps1'

    # --- scripts (Phase 3 downloads these) ---
    'scripts/health-check.ps1'                 = 'scripts/health-check.ps1'
    'scripts/disk-monitor.ps1'                 = 'scripts/disk-monitor.ps1'
    'scripts/docker-watchdog.ps1'              = 'scripts/docker-watchdog.ps1'
    'scripts/kill-stale-containers.ps1'        = 'scripts/kill-stale-containers.ps1'
    'scripts/Register-ScheduledTasks.ps1'      = 'scripts/Register-ScheduledTasks.ps1'
    'scripts/Import-Certificates.ps1'          = 'scripts/Import-Certificates.ps1'
    'scripts/Enable-RemotePowerShell.ps1'      = 'scripts/Enable-RemotePowerShell.ps1'
    'scripts/Test-NetworkConnectivity.ps1'     = 'scripts/Test-NetworkConnectivity.ps1'
    'scripts/Write-JobLog.ps1'                 = 'scripts/Write-JobLog.ps1'
    'scripts/Export-RdpAuditLog.ps1'           = 'scripts/Export-RdpAuditLog.ps1'
    'scripts/Export-RunnerLogs.ps1'            = 'scripts/Export-RunnerLogs.ps1'
    'scripts/Write-GoldenVersion.ps1'          = 'scripts/Write-GoldenVersion.ps1'

    # --- tools (config files only -- binaries are uploaded manually) ---
    'tools/opencode/opencode.jsonc'            = 'tools/opencode/opencode.jsonc'
}

# ============================================================
# S3 PUT (AWS Signature V4)
# ============================================================

function Put-S3Object {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$FilePath
    )

    $uri      = [System.Uri]$Endpoint
    $hostName = $uri.Host
    if ($uri.Port -ne 443 -and $uri.Port -ne 80) { $hostName = "$($uri.Host):$($uri.Port)" }

    $fileBytes   = [System.IO.File]::ReadAllBytes($FilePath)
    $payloadHash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash($fileBytes)
    ).Replace('-','').ToLower()

    $now       = [DateTime]::UtcNow
    $dateStamp = $now.ToString('yyyyMMdd')
    $amzDate   = $now.ToString('yyyyMMddTHHmmssZ')

    $encodedKey       = ($Key -split '/' | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
    $canonicalUri     = "/$Bucket/$encodedKey"
    $canonicalHeaders = "host:$hostName`nx-amz-content-sha256:$payloadHash`nx-amz-date:$amzDate`n"
    $signedHeaders    = 'host;x-amz-content-sha256;x-amz-date'
    $canonicalRequest = "PUT`n$canonicalUri`n`n$canonicalHeaders`n$signedHeaders`n$payloadHash"

    $credentialScope = "$dateStamp/$Region/s3/aws4_request"
    $canonicalHash   = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($canonicalRequest)
        )
    ).Replace('-','').ToLower()

    $stringToSign = "AWS4-HMAC-SHA256`n$amzDate`n$credentialScope`n$canonicalHash"

    function HmacSHA256([byte[]]$key, [string]$data) {
        $hmac = New-Object System.Security.Cryptography.HMACSHA256
        $hmac.Key = $key
        return $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($data))
    }

    $kSecret   = [System.Text.Encoding]::UTF8.GetBytes("AWS4$SecretKey")
    $kDate     = HmacSHA256 $kSecret  $dateStamp
    $kRegion   = HmacSHA256 $kDate    $Region
    $kService  = HmacSHA256 $kRegion  's3'
    $kSigning  = HmacSHA256 $kService 'aws4_request'
    $signature = [System.BitConverter]::ToString((HmacSHA256 $kSigning $stringToSign)).Replace('-','').ToLower()

    $authHeader = "AWS4-HMAC-SHA256 Credential=$AccessKey/$credentialScope, SignedHeaders=$signedHeaders, Signature=$signature"
    $url = "$Endpoint/$Bucket/$Key"

    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('Authorization', $authHeader)
    $wc.Headers.Add('x-amz-content-sha256', $payloadHash)
    $wc.Headers.Add('x-amz-date', $amzDate)
    $wc.Headers.Add('Content-Type', 'application/octet-stream')
    $wc.UploadData($url, 'PUT', $fileBytes) | Out-Null
}

# ============================================================
# MAIN -- Sync files
# ============================================================

$repoRoot = Split-Path $PSScriptRoot -Parent
$uploaded = 0
$skipped  = 0
$failed   = 0

Write-Output "============================================"
Write-Output "Sync-ToMinio -- $Endpoint/$Bucket"
Write-Output "Repo root: $repoRoot"
Write-Output "Files to sync: $($FileMap.Count)"
if ($DryRun) { Write-Output "MODE: DRY RUN" }
Write-Output "============================================"

foreach ($entry in $FileMap.GetEnumerator()) {
    $repoFile = Join-Path $repoRoot $entry.Key
    $s3Key    = $entry.Value

    if (-not (Test-Path $repoFile)) {
        Write-Output "  SKIP (not in repo): $($entry.Key)"
        $skipped++
        continue
    }

    $sizeKB = [math]::Round((Get-Item $repoFile).Length / 1KB, 1)

    if ($DryRun) {
        Write-Output "  WOULD UPLOAD: $($entry.Key) -> $s3Key ($sizeKB KB)"
        $uploaded++
        continue
    }

    try {
        Put-S3Object -Key $s3Key -FilePath $repoFile
        Write-Output "  UPLOADED: $($entry.Key) -> $s3Key ($sizeKB KB)"
        $uploaded++
    }
    catch {
        Write-Output "  FAILED: $($entry.Key) -> $s3Key : $_"
        $failed++
    }
}

Write-Output "============================================"
Write-Output "Result: $uploaded uploaded, $skipped skipped, $failed failed"
Write-Output "============================================"

if ($failed -gt 0) {
    Write-Output "ERROR: $failed file(s) failed to upload"
    exit 1
}
