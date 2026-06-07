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
# Single source of truth shared with validation/Test-Dependencies.ps1.
# ============================================================

. (Join-Path $PSScriptRoot 'FileMap.ps1')
. (Join-Path $PSScriptRoot 'Substitute-Aliases.ps1')

# ============================================================
# S3 PUT (AWS Signature V4)
# ============================================================

function Put-S3Object {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$FilePath,
        # Optional override -- routes this single PUT to a different bucket
        # while keeping the same endpoint/credentials. Used to ship
        # Bootstrap-GitLabRunner.ps1 to a Be1-readable bucket when
        # $env:BOOTSTRAP_S3_PATH is set.
        [string]$BucketOverride = $null
    )

    $effectiveBucket = if ($BucketOverride) { $BucketOverride } else { $Bucket }

    $uri      = [System.Uri]$Endpoint
    $hostName = $uri.Host
    if ($uri.Port -ne 443 -and $uri.Port -ne 80) { $hostName = "$($uri.Host):$($uri.Port)" }

    $fileBytes   = [System.IO.File]::ReadAllBytes($FilePath)
    # Apply alias->real substitution (no-op when REAL_* env vars are unset).
    # Must happen BEFORE the SHA256 + ETag derivation -- MinIO's ETag is
    # MD5(content-as-uploaded), so verify-minio's MD5 has to match what
    # actually went over the wire, not what was on disk.
    $fileBytes   = Convert-Aliases -ContentBytes $fileBytes
    $payloadHash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash($fileBytes)
    ).Replace('-','').ToLower()

    $now       = [DateTime]::UtcNow
    $dateStamp = $now.ToString('yyyyMMdd')
    $amzDate   = $now.ToString('yyyyMMddTHHmmssZ')

    $encodedKey       = ($Key -split '/' | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
    $canonicalUri     = "/$effectiveBucket/$encodedKey"
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
    $url = "$Endpoint/$effectiveBucket/$Key"

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
if (Test-AliasSubstitutionActive) {
    Write-Output "Alias substitution: ACTIVE (file content will be rewritten before upload)"
    foreach ($s in (Get-ActiveSubstitutions)) {
        Write-Output ("  {0,-22} -> {1} (from `$env:{2})" -f $s.Alias, $s.Real, $s.Env)
    }
} else {
    Write-Output "Alias substitution: inactive (no REAL_* env vars set; content uploaded verbatim)"
}
if ($DryRun) { Write-Output "MODE: DRY RUN" }
Write-Output "============================================"

# Bootstrap routing: optional env var BOOTSTRAP_S3_PATH (format: 'bucket/key')
# sends Bootstrap-GitLabRunner.ps1 to a separate bucket while leaving everything
# else in $Bucket. Same MinIO credentials. Useful when Be1's MinIO permissions
# don't extend to gitlab-runner-golden.
$Script:BootstrapDefaultRepo = 'Bootstrap-GitLabRunner.ps1'
$Script:BootstrapAltBucket   = $null
$Script:BootstrapAltKey      = $null
$bsPath = [Environment]::GetEnvironmentVariable('BOOTSTRAP_S3_PATH')
if ($bsPath) {
    $slash = $bsPath.IndexOf('/')
    if ($slash -lt 1) {
        Write-Output "  WARN: BOOTSTRAP_S3_PATH='$bsPath' not in 'bucket/key' form -- using default bucket for bootstrap"
    } else {
        $Script:BootstrapAltBucket = $bsPath.Substring(0, $slash)
        $Script:BootstrapAltKey    = $bsPath.Substring($slash + 1)
        Write-Output "  Bootstrap routing: $Script:BootstrapDefaultRepo -> $($Script:BootstrapAltBucket)/$($Script:BootstrapAltKey)"
        Write-Output ''
    }
}

# Upload the bootstrap script LAST. If a runner re-triggers mid-sync it must
# never fetch a Bootstrap-GitLabRunner.ps1 that references scripts/phases not
# yet uploaded -- every other file lands first, the bootstrap seals the set.
$orderedEntries = @(
    $FileMap.GetEnumerator() | Where-Object { $_.Key -ne $Script:BootstrapDefaultRepo }
) + @(
    $FileMap.GetEnumerator() | Where-Object { $_.Key -eq $Script:BootstrapDefaultRepo }
)
foreach ($entry in $orderedEntries) {
    $repoFile = Join-Path $repoRoot $entry.Key
    $s3Key    = $entry.Value
    $bucketOverrideArgs = @{}
    $bucketLabel        = $Bucket

    if ($Script:BootstrapAltBucket -and $entry.Key -eq $Script:BootstrapDefaultRepo) {
        $s3Key                              = $Script:BootstrapAltKey
        $bucketOverrideArgs.BucketOverride  = $Script:BootstrapAltBucket
        $bucketLabel                        = $Script:BootstrapAltBucket
    }

    if (-not (Test-Path $repoFile)) {
        Write-Output "  SKIP (not in repo): $($entry.Key)"
        $skipped++
        continue
    }

    $sizeKB = [math]::Round((Get-Item $repoFile).Length / 1KB, 1)

    if ($DryRun) {
        Write-Output "  WOULD UPLOAD: $($entry.Key) -> $bucketLabel/$s3Key ($sizeKB KB)"
        $uploaded++
        continue
    }

    try {
        Put-S3Object -Key $s3Key -FilePath $repoFile @bucketOverrideArgs
        Write-Output "  UPLOADED: $($entry.Key) -> $bucketLabel/$s3Key ($sizeKB KB)"
        $uploaded++
    }
    catch {
        Write-Output "  FAILED: $($entry.Key) -> $bucketLabel/$s3Key : $_"
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
