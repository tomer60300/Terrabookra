#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Be1 Post-Install Bootstrap -- GitLab Runner Golden Image (Docker Executor, Windows)

.DESCRIPTION
    Single entry point fetched by VMware Aria (Be1) from MinIO.
    This is the ONLY file Be1 needs -- it bootstraps everything else.

    Execution flow:
      Phase 0 (bootstrap) : Download lib/, phases/, validation/ from MinIO
      Phase 1             : System prep, services, env vars, dirs, features -> REBOOT
      Phase 2             : Docker daemon.json, binaries, dockerd service   -> REBOOT
      Phase 3             : Runner install, registration, maintenance, validation

    Be1 triggers this script after every reboot. Marker files control which
    phase runs next. Phase 0 is idempotent -- skips files already on disk.

    All binaries from MinIO bucket "gitlab-runner-golden" via AWS Sig V4.
    All container images from Harbor project "golden-image".

.NOTES
    Target OS:       Windows Server 2019 LTSC (Build 17763)
    GitLab:          16.7.10-ee (self-managed, self-signed cert)
    Runner:          16.7.0
    Docker:          25.0.15 (raw docker.exe + dockerd.exe)
    Executor:        docker-windows (process isolation)

    Disk layout expected:
      C: (100 GB) -- OS, runner binary, tools
      E: (1 TB)   -- Docker data-root, pagefile, builds, cache

    Be1 workflow:
      1. Be1 creates VM, joins domain, sets general settings
      2. Be1 sets env var: RUNNER_TOKEN = glrt-XXXX
      3. Be1 fetches this single file from MinIO
      4. Be1 triggers: Bootstrap-GitLabRunner.ps1
      5. After each reboot, Be1 re-triggers the same script
#>

# ============================================================
# BOOTSTRAP CONFIG -- MinIO connection for self-download
# Edit ONLY these values to match your environment.
# ============================================================

$Script:BootstrapEndpoint  = 'https://kayhut-minio.com:9000'
$Script:BootstrapBucket    = 'gitlab-runner-golden'
$Script:BootstrapAccessKey = 'YOUR_ACCESS_KEY_HERE'
$Script:BootstrapSecretKey = 'YOUR_SECRET_KEY_HERE'
$Script:BootstrapRegion    = 'us-east-1'
$Script:BootstrapDir       = 'C:\GitLab-Runner'

# ============================================================
# TLS BYPASS (self-signed certs -- must run before any S3 call)
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
# BOOTSTRAP LOGGING (minimal -- before Common.ps1 is loaded)
# ============================================================

$Script:BootstrapLogFile = 'C:\GitLab-Runner\logs\install.log'

function Write-BootstrapLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    $dir  = Split-Path $Script:BootstrapLogFile -Parent
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $line | Out-File -FilePath $Script:BootstrapLogFile -Append -Encoding UTF8
    Write-Output $line
}

# ============================================================
# BOOTSTRAP S3 DOWNLOAD (standalone -- no dependencies)
# ============================================================

function Get-BootstrapS3Object {
    <#
    .SYNOPSIS  Download a single object from MinIO using AWS Signature V4.
               Standalone function -- does not depend on Config.ps1 or Common.ps1.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$OutFile
    )

    $endpoint  = $Script:BootstrapEndpoint
    $bucket    = $Script:BootstrapBucket
    $accessKey = $Script:BootstrapAccessKey
    $secretKey = $Script:BootstrapSecretKey
    $region    = $Script:BootstrapRegion

    $uri      = [System.Uri]$endpoint
    $hostName = $uri.Host
    if ($uri.Port -ne 443 -and $uri.Port -ne 80) { $hostName = "$($uri.Host):$($uri.Port)" }

    $now       = [DateTime]::UtcNow
    $dateStamp = $now.ToString('yyyyMMdd')
    $amzDate   = $now.ToString('yyyyMMddTHHmmssZ')

    $encodedKey       = ($Key -split '/' | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
    $canonicalUri     = "/$bucket/$encodedKey"
    $payloadHash      = 'UNSIGNED-PAYLOAD'
    $canonicalHeaders = "host:$hostName`nx-amz-content-sha256:$payloadHash`nx-amz-date:$amzDate`n"
    $signedHeaders    = 'host;x-amz-content-sha256;x-amz-date'
    $canonicalRequest = "GET`n$canonicalUri`n`n$canonicalHeaders`n$signedHeaders`n$payloadHash"

    $credentialScope = "$dateStamp/$region/s3/aws4_request"
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

    $kSecret   = [System.Text.Encoding]::UTF8.GetBytes("AWS4$secretKey")
    $kDate     = HmacSHA256 $kSecret  $dateStamp
    $kRegion   = HmacSHA256 $kDate    $region
    $kService  = HmacSHA256 $kRegion  's3'
    $kSigning  = HmacSHA256 $kService 'aws4_request'
    $signature = [System.BitConverter]::ToString((HmacSHA256 $kSigning $stringToSign)).Replace('-','').ToLower()

    $authHeader = "AWS4-HMAC-SHA256 Credential=$accessKey/$credentialScope, SignedHeaders=$signedHeaders, Signature=$signature"
    $url = "$endpoint/$bucket/$Key"

    $outDir = Split-Path $OutFile -Parent
    if (-not (Test-Path $outDir)) { New-Item -Path $outDir -ItemType Directory -Force | Out-Null }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('Authorization', $authHeader)
            $wc.Headers.Add('x-amz-content-sha256', $payloadHash)
            $wc.Headers.Add('x-amz-date', $amzDate)
            $wc.DownloadFile($url, $OutFile)
            if (Test-Path $OutFile) {
                $size = (Get-Item $OutFile).Length
                if ($size -eq 0) {
                    throw "Downloaded file is empty (0 bytes)"
                }
                # Detect S3/MinIO XML error responses saved as files
                $head = Get-Content $OutFile -TotalCount 1 -ErrorAction SilentlyContinue
                if ($head -and ($head -match '^\s*<\?xml' -or $head -match '^\s*<Error')) {
                    $errContent = Get-Content $OutFile -Raw -ErrorAction SilentlyContinue
                    Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
                    throw "MinIO returned an error response (check credentials/bucket): $($errContent.Substring(0, [Math]::Min(200, $errContent.Length)))"
                }
                Write-BootstrapLog "Downloaded $Key -> $OutFile ($size bytes)"
                return $true
            }
        }
        catch {
            Write-BootstrapLog "Download attempt $attempt/3 failed for $Key : $_" 'WARN'
            Start-Sleep -Seconds ($attempt * 5)
        }
    }
    Write-BootstrapLog "FAILED to download $Key after 3 attempts" 'ERROR'
    return $false
}

# ============================================================
# PHASE 0 -- Bootstrap: download project files from MinIO
# ============================================================

$Script:ScriptRoot = $Script:BootstrapDir

# Files the orchestrator needs to dot-source and run.
# Key = S3 object key, Value = local path relative to $Script:BootstrapDir
$Script:BootstrapFiles = [ordered]@{
    # --- lib (must be first -- phases depend on them) ---
    'bootstrap/lib/Config.ps1'                    = 'lib\Config.ps1'
    'bootstrap/lib/Common.ps1'                    = 'lib\Common.ps1'
    # --- phases ---
    'bootstrap/phases/Phase1-SystemPrep.ps1'      = 'phases\Phase1-SystemPrep.ps1'
    'bootstrap/phases/Phase2-DockerInstall.ps1'    = 'phases\Phase2-DockerInstall.ps1'
    'bootstrap/phases/Phase3-RunnerSetup.ps1'      = 'phases\Phase3-RunnerSetup.ps1'
    # --- validation ---
    'bootstrap/validation/Invoke-FinalValidation.ps1' = 'validation\Invoke-FinalValidation.ps1'
}

function Invoke-Phase0 {
    <#
    .SYNOPSIS  Download lib/, phases/, and validation/ scripts from MinIO.
               Idempotent -- skips files that already exist on disk.
    #>
    Write-BootstrapLog '========== PHASE 0 -- BOOTSTRAP (download project files from MinIO) =========='

    $downloaded = 0
    $skipped    = 0
    $failed     = 0

    foreach ($entry in $Script:BootstrapFiles.GetEnumerator()) {
        $s3Key   = $entry.Key
        $relPath = $entry.Value
        $absPath = Join-Path $Script:BootstrapDir $relPath

        if (Test-Path $absPath) {
            Write-BootstrapLog "  SKIP (exists): $relPath"
            $skipped++
            continue
        }

        $ok = Get-BootstrapS3Object -Key $s3Key -OutFile $absPath
        if ($ok) {
            $downloaded++
        } else {
            $failed++
        }
    }

    Write-BootstrapLog "Phase 0 result: $downloaded downloaded, $skipped skipped, $failed failed"

    if ($failed -gt 0) {
        Write-BootstrapLog 'FATAL: Phase 0 bootstrap failed -- cannot continue without project files.' 'ERROR'
        exit 1
    }

    # Log directory listing so the operator can verify file placement
    Write-BootstrapLog "Project files on disk ($Script:BootstrapDir):"
    foreach ($sub in @('lib', 'phases', 'validation')) {
        $dir = Join-Path $Script:BootstrapDir $sub
        if (Test-Path $dir) {
            foreach ($f in (Get-ChildItem -Path $dir -File)) {
                $sizeKB = [math]::Round($f.Length / 1KB, 1)
                Write-BootstrapLog "  $sub\$($f.Name)  (${sizeKB} KB)"
            }
        }
    }

    Write-BootstrapLog '========== PHASE 0 COMPLETE =========='
}

# ============================================================
# MAIN
# ============================================================

try {
    # Read version stamp
    $versionFile = Join-Path $PSScriptRoot 'VERSION'
    if (-not (Test-Path $versionFile)) { $versionFile = Join-Path $Script:BootstrapDir 'VERSION' }
    $versionStamp = if (Test-Path $versionFile) { (Get-Content $versionFile -First 1).Trim() } else { 'unknown' }

    Write-BootstrapLog '============================================'
    Write-BootstrapLog "Bootstrap-GitLabRunner.ps1 -- START"
    Write-BootstrapLog "Version: $versionStamp"
    Write-BootstrapLog "Host: $env:COMPUTERNAME | OS: $([System.Environment]::OSVersion.VersionString)"
    Write-BootstrapLog "Script root: $Script:ScriptRoot"
    Write-BootstrapLog '============================================'

    # --- Phase 0: Bootstrap project files ---
    Invoke-Phase0

    # --- Dot-source project modules (now available on disk) ---
    . (Join-Path $Script:ScriptRoot 'lib\Config.ps1')
    . (Join-Path $Script:ScriptRoot 'lib\Common.ps1')
    . (Join-Path $Script:ScriptRoot 'phases\Phase1-SystemPrep.ps1')
    . (Join-Path $Script:ScriptRoot 'phases\Phase2-DockerInstall.ps1')
    . (Join-Path $Script:ScriptRoot 'phases\Phase3-RunnerSetup.ps1')
    . (Join-Path $Script:ScriptRoot 'validation\Invoke-FinalValidation.ps1')

    Write-Log '============================================'
    Write-Log "Bootstrap-GitLabRunner.ps1 -- Phase dispatch"
    Write-Log "Data drive: $Script:DataDrive"
    Write-Log '============================================'

    # --- Phase dispatch based on marker files ---
    if (Test-PhaseComplete $Script:Config.Phase2Marker) {
        Write-Log 'Phase 2 marker found -> dispatching Phase 3'
        Invoke-Phase3
    }
    elseif (Test-PhaseComplete $Script:Config.Phase1Marker) {
        Write-Log 'Phase 1 marker found -> dispatching Phase 2'
        Invoke-Phase2
    }
    else {
        Write-Log 'No markers found -> dispatching Phase 1'
        Invoke-Phase1
    }
}
catch {
    $errMsg = "UNHANDLED EXCEPTION: $($_.Exception.Message)"
    $stack  = "Stack trace: $($_.ScriptStackTrace)"
    # Use Write-Log if available (post phase 0), fallback to bootstrap log
    if (Get-Command Write-LogError -ErrorAction SilentlyContinue) {
        Write-LogError $errMsg
        Write-LogError $stack
    } else {
        Write-BootstrapLog $errMsg 'ERROR'
        Write-BootstrapLog $stack 'ERROR'
    }
    exit 1
}
