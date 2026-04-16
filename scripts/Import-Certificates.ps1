<#
.SYNOPSIS
    Import self-signed certificates into the Windows Local Machine Trusted Root store.

.DESCRIPTION
    Scans $CertsDir for .crt, .cer, and .pem certificate files and imports each
    into Cert:\LocalMachine\Root. Skips certificates that are already trusted.
    Called during Phase 1 (step 1.10).

    This is an ADDITIONAL trust layer — GIT_SSL_NO_VERIFY and insecure-registries
    remain as fallback bypasses.

.NOTES
    File: scripts/Import-Certificates.ps1
    Event IDs:
      9020 — Certificate imported successfully
      9021 — Certificate import failed

    Default cert location: C:\GitLab-Runner\certs\
    Expected files: gitlab.kayhut.com.crt (and optionally harbor, minio, etc.)
#>

param(
    [string]$CertsDir = 'C:\GitLab-Runner\certs'
)

$ErrorActionPreference = 'Continue'
$source = 'GitLabRunner'

if (-not (Test-Path $CertsDir)) {
    Write-Output "Certs directory not found: $CertsDir — skipping import"
    return
}

$certFiles = Get-ChildItem -Path $CertsDir -File | Where-Object {
    $_.Extension -in '.crt', '.cer', '.pem'
}

if ($certFiles.Count -eq 0) {
    Write-Output "No certificate files (.crt/.cer/.pem) found in $CertsDir"
    return
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
            Write-Output "  [SKIP] $($file.Name) — already in Trusted Root (thumbprint: $thumbprint)"
            $skipped++
            continue
        }

        $store.Add($cert)
        $imported++
        Write-Output "  [OK] $($file.Name) — imported to Trusted Root (thumbprint: $thumbprint, subject: $($cert.Subject))"

        Write-EventLog -LogName Application -Source $source -EventId 9020 -EntryType Information `
            -Message "Certificate imported: $($file.Name) | Subject: $($cert.Subject) | Thumbprint: $thumbprint"
    }
    catch {
        Write-Output "  [FAIL] $($file.Name) — $_"
        Write-EventLog -LogName Application -Source $source -EventId 9021 -EntryType Warning `
            -Message "Certificate import failed: $($file.Name) | Error: $_"
    }
}

$store.Close()
Write-Output "Certificate import complete: $imported imported, $skipped skipped"
