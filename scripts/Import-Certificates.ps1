<#
.SYNOPSIS
    Fetch certificates from MinIO S3 and import into the Windows Trusted Root store.

.DESCRIPTION
    1. Downloads .crt files listed in $Script:Config.S3Certs from MinIO to $CertsDir
    2. Scans $CertsDir for .crt, .cer, and .pem files
    3. Imports each into Cert:\LocalMachine\Root (skips already-trusted)

    Called during Phase 1 (step 1.10).

    This is an ADDITIONAL trust layer -- GIT_SSL_NO_VERIFY and insecure-registries
    remain as fallback bypasses.

.NOTES
    File: scripts/Import-Certificates.ps1
    Requires: lib/Config.ps1, lib/Common.ps1 (dot-sourced by orchestrator)
    Event IDs:
      9020 -- Certificate imported successfully
      9021 -- Certificate import failed
      9022 -- Certificate download from S3 failed

    Default cert location: C:\GitLab-Runner\certs\
#>

param(
    [string]$CertsDir = $Script:Config.CertsDir
)

if (-not $CertsDir) { $CertsDir = 'C:\GitLab-Runner\certs' }

$ErrorActionPreference = 'Continue'
$source = 'GitLabRunner'

# Failure counters. This script MUST exit non-zero on any download/import
# failure so Phase 1's $LASTEXITCODE gate aborts before writing its marker --
# an untrusted internal CA breaks Harbor/GitLab TLS on the air-gapped runner.
$dlFailures     = 0
$importFailures = 0

# -- Ensure certs directory exists ----------------------------
if (-not (Test-Path $CertsDir)) {
    New-Item -Path $CertsDir -ItemType Directory -Force | Out-Null
}

# -- Step 1: Stage certificates from the uploaded repo -------
$s3Certs = $Script:Config.S3Certs
if ($s3Certs -and $s3Certs.Count -gt 0) {
    Write-Output "Staging $($s3Certs.Count) certificate(s) from repo..."
    foreach ($certKey in $s3Certs) {
        $fileName = Split-Path $certKey -Leaf
        $destPath = Join-Path $CertsDir $fileName
        # Skip the S3 fetch if the cert file is already on disk with non-zero
        # size. Re-running this script across phases (or after a reboot) would
        # otherwise re-download the same bytes for no reason. The trust-store
        # check below is still authoritative -- if the cert was already imported
        # in a prior run, we'll skip the import too.
        if ((Test-Path $destPath) -and ((Get-Item $destPath).Length -gt 0)) {
            Write-Output "  [SKIP DL] $fileName -- already in $CertsDir ($((Get-Item $destPath).Length) bytes)"
            continue
        }
        $ok = Copy-RepoFile -RelPath $certKey -OutFile $destPath
        if ($ok) {
            Write-Output "  [DL] $certKey -> $destPath"
        } else {
            Write-Output "  [FAIL] Could not stage $certKey from repo"
            $dlFailures++
            Write-EventLog -LogName Application -Source $source -EventId 9022 -EntryType Warning `
                -Message "Certificate S3 download failed: $certKey"
        }
    }
} else {
    Write-Output "No S3 certificate keys configured -- scanning local certs only"
}

# -- Step 2: Import all certs found in CertsDir --------------
$certFiles = Get-ChildItem -Path $CertsDir -File | Where-Object {
    $_.Extension -in '.crt', '.cer', '.pem'
}

if ($certFiles.Count -eq 0) {
    if (($s3Certs -and $s3Certs.Count -gt 0) -or $dlFailures -gt 0) {
        Write-Output "FATAL: certificates are configured but none are present in $CertsDir (download failures: $dlFailures)."
        exit 1
    }
    Write-Output "No certificate files (.crt/.cer/.pem) found in $CertsDir, and none configured -- nothing to import."
    exit 0
}

$store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
    'Root', 'LocalMachine'
)
$store.Open('ReadWrite')

$imported = 0
$skipped  = 0

foreach ($file in $certFiles) {
    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($file.FullName)
        $thumbprint = $cert.Thumbprint

        # Check if already trusted
        $existing = $store.Certificates | Where-Object { $_.Thumbprint -eq $thumbprint }
        if ($existing) {
            Write-Output "  [SKIP] $($file.Name) -- already in Trusted Root (thumbprint: $thumbprint)"
            $skipped++
            continue
        }

        $store.Add($cert)
        $imported++
        Write-Output "  [OK] $($file.Name) -- imported to Trusted Root (thumbprint: $thumbprint, subject: $($cert.Subject))"

        Write-EventLog -LogName Application -Source $source -EventId 9020 -EntryType Information `
            -Message "Certificate imported: $($file.Name) | Subject: $($cert.Subject) | Thumbprint: $thumbprint"
    }
    catch {
        Write-Output "  [FAIL] $($file.Name) -- $_"
        $importFailures++
        Write-EventLog -LogName Application -Source $source -EventId 9021 -EntryType Warning `
            -Message "Certificate import failed: $($file.Name) | Error: $_"
    }
}

$store.Close()
Write-Output "Certificate import complete: $imported imported, $skipped skipped, $importFailures failed (download failures: $dlFailures)"

# Exit non-zero on ANY failure so the Phase 1 gate aborts before the marker.
if ($dlFailures -gt 0 -or $importFailures -gt 0) {
    Write-Output "FATAL: certificate provisioning incomplete -- $dlFailures download, $importFailures import failure(s)."
    exit 1
}
exit 0
