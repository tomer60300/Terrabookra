<#
.SYNOPSIS
    Common helpers -- TLS bypass, logging, S3 download, PE validation, phase markers, reboot.

.DESCRIPTION
    Dot-sourced by Bootstrap-GitLabRunner.ps1 after Config.ps1.
    Provides all shared functions used across phases.

.NOTES
    File: lib/Common.ps1
    Used by: Bootstrap-GitLabRunner.ps1, phases/*.ps1, validation/*.ps1

    Functions exported:
      Write-Log, Write-LogError, Write-LogWarn
      Get-S3Object
      Test-PEBinary, Install-S3Binary, Install-S3Archive
      Wait-ServiceRunning
      Get-DnsServer
      Invoke-Be1Reboot
      Set-PhaseMarker, Test-PhaseComplete
#>

# ============================================================
# TLS BYPASS -- Guard against re-add on Be1 re-run
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

function Write-Log {
    <#
    .SYNOPSIS  Write a timestamped line to the install log and stdout.
    #>
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    $dir  = Split-Path $Script:LogFile -Parent
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $line | Out-File -FilePath $Script:LogFile -Append -Encoding UTF8
    Write-Output $line
}

function Write-LogError { param([string]$Message) Write-Log -Message $Message -Level 'ERROR' }
function Write-LogWarn  { param([string]$Message) Write-Log -Message $Message -Level 'WARN'  }

# ============================================================
# S3 DOWNLOAD (MinIO -- AWS Signature V4)
# ============================================================

function Get-S3Object {
    <#
    .SYNOPSIS  Download an object from MinIO using AWS Signature V4.
    .PARAMETER Key      S3 object key (e.g. 'binaries/docker/docker.exe')
    .PARAMETER OutFile  Local destination path
    .OUTPUTS   [bool]   $true on success
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$OutFile
    )

    $endpoint  = $Script:Config.MinioEndpoint
    $bucket    = $Script:Config.MinioBucket
    $accessKey = $Script:Config.MinioAccessKey
    $secretKey = $Script:Config.MinioSecretKey
    $region    = $Script:Config.MinioRegion

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
                    throw "MinIO returned an error response: $($errContent.Substring(0, [Math]::Min(200, $errContent.Length)))"
                }
                Write-Log "Downloaded $Key -> $OutFile ($size bytes)"
                return $true
            }
        }
        catch {
            Write-LogWarn "Download attempt $attempt/3 failed for $Key : $_"
            Start-Sleep -Seconds ($attempt * 5)
        }
    }
    Write-LogError "FAILED to download $Key after 3 attempts"
    return $false
}

# ============================================================
# BINARY HELPERS
# ============================================================

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

function Install-S3Binary {
    <#
    .SYNOPSIS  Download an EXE from S3 and validate its PE header.
    #>
    param([string]$S3Key, [string]$DestPath, [string]$Label)
    if (Test-PEBinary $DestPath) { Write-Log "$Label already present"; return $true }
    $ok = Get-S3Object -Key $S3Key -OutFile $DestPath
    if ($ok -and (Test-PEBinary $DestPath)) { Write-Log "$Label downloaded and validated"; return $true }
    Write-LogError "FATAL: $Label -- download or validation failed"
    return $false
}

function Install-S3Archive {
    <#
    .SYNOPSIS  Download a ZIP from S3 and extract it.
    #>
    param([string]$S3Key, [string]$DestDir, [string]$TestFile, [string]$Label)
    if ($TestFile -and (Test-Path $TestFile)) { Write-Log "$Label already present"; return $true }
    $zipPath = Join-Path $env:TEMP "s3_$(Split-Path $S3Key -Leaf)"
    $ok = Get-S3Object -Key $S3Key -OutFile $zipPath
    if ($ok) {
        Expand-Archive -Path $zipPath -DestinationPath $DestDir -Force
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Write-Log "$Label extracted to $DestDir"
        return $true
    }
    Write-LogError "FATAL: $Label -- download failed"
    return $false
}

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
    #>
    $servers = @()
    try {
        $adapters = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.ServerAddresses.Count -gt 0 }
        foreach ($a in $adapters) { $servers += $a.ServerAddresses }
        $servers = $servers | Select-Object -Unique | Select-Object -First 2
    }
    catch { Write-LogWarn "DNS auto-detect failed: $_" }
    return $servers
}

# ============================================================
# Be1 REBOOT + PHASE MARKERS
# ============================================================

function Invoke-Be1Reboot {
    <#
    .SYNOPSIS  Request a Be1-compatible reboot (POWER_ON + exit 3010).
    #>
    param([string]$Reason = 'GitLab Runner setup phase complete')
    Write-Log "Requesting reboot: $Reason"
    shutdown.exe /r /t 15 /c $Reason /d p:4:1
    Write-Output 'POWER_ON'
    exit 3010
}

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
    .SYNOPSIS  Check if a phase marker exists and is fresh (< StaleMinutes old).
    #>
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $age = (Get-Date) - (Get-Item $Path).LastWriteTime
    if ($age.TotalMinutes -gt $Script:Config.StaleMinutes) {
        Write-LogWarn "Phase marker $Path is stale ($([int]$age.TotalMinutes) min). Re-running phase."
        Remove-Item $Path -Force
        return $false
    }
    return $true
}
