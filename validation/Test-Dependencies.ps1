<#
.SYNOPSIS
    Pre-flight dependency validator -- DNS, MinIO S3 objects, Harbor images.

.DESCRIPTION
    Dry-checks that every external dependency is reachable BEFORE the install
    begins. No files are downloaded; no images are pulled.

    Three check categories:
      1. DNS -- resolves every hostname from Config.MonitorHosts
      2. MinIO S3 -- HEAD request (AWS SigV4) for all S3 objects (keys, extras, certs, bootstrap)
      3. Harbor -- Registry API v2 manifest HEAD for all pre-pull images

    Can run in two modes:
      Standalone  : dot-sources lib/Config.ps1 (and lib/Common.ps1 for TLS bypass)
      Integrated  : called from the orchestrator where $Script:Config already exists

    Usage (standalone -- from the project root):
      .\validation\Test-Dependencies.ps1

    Usage (from admin PC targeting a runner):
      Invoke-Command -ComputerName runner01 -ScriptBlock {
          C:\GitLab-Runner\scripts\Test-Dependencies.ps1
      }

    Exit codes:
      0 = all checks passed
      1 = one or more checks failed

.PARAMETER SkipDns
    Skip DNS resolution checks.

.PARAMETER SkipS3
    Skip MinIO S3 artifact checks.

.PARAMETER SkipHarbor
    Skip Harbor image manifest checks.

.NOTES
    File: validation/Test-Dependencies.ps1
    Requires: lib/Config.ps1 (dot-sourced automatically if not already loaded)
#>

param(
    [switch]$SkipDns,
    [switch]$SkipS3,
    [switch]$SkipHarbor
)

$ErrorActionPreference = 'Continue'

# ============================================================
# BOOTSTRAP -- load Config if not already dot-sourced
# ============================================================

if (-not $Script:Config) {
    # Try to find project root (where lib/Config.ps1 lives)
    $projectRoot = $PSScriptRoot
    if (-not (Test-Path (Join-Path $projectRoot 'lib\Config.ps1'))) {
        $projectRoot = Split-Path $PSScriptRoot -Parent
    }
    $configPath = Join-Path $projectRoot 'lib\Config.ps1'
    if (Test-Path $configPath) {
        . $configPath
    } else {
        Write-Host '[FATAL] Cannot find lib\Config.ps1 -- run from project root or ensure $Script:Config is loaded.' -ForegroundColor Red
        exit 1
    }
}

# TLS bypass (self-signed certs)
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
# FILE MAP -- inverse lookup (S3 key -> repo path) so the content-match
# check can compute the local MD5 for each S3 key. Sourced from the same
# ci/FileMap.ps1 file Sync-ToMinio.ps1 uses, so they can never drift.
# Repo files NOT in $FileMap (e.g. binary tools uploaded out-of-band via
# USB) get a HEAD existence check only, no MD5 comparison.
# ============================================================

$Script:S3KeyToRepoPath = @{}
$mapPath = Join-Path (Split-Path $Script:Config.PSScriptRoot -ErrorAction SilentlyContinue) 'ci\FileMap.ps1'
if (-not (Test-Path $mapPath)) {
    # Try walking up from this script's location: validation/ -> repo root -> ci/
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $mapPath = Join-Path $repoRoot 'ci\FileMap.ps1'
}
if (Test-Path $mapPath) {
    . $mapPath
    foreach ($entry in $Script:FileMap.GetEnumerator()) {
        $Script:S3KeyToRepoPath[$entry.Value] = $entry.Key
    }
    Write-Host "  Loaded FileMap from $mapPath ($($Script:S3KeyToRepoPath.Count) entries)" -ForegroundColor DarkGray
} else {
    Write-Host "  WARN: ci/FileMap.ps1 not found -- content-match check will be skipped" -ForegroundColor Yellow
}

# Optional: source the alias-substitution helper. When CI env vars REAL_* are
# set, Sync-ToMinio.ps1 rewrites file content before upload -- so to keep the
# MD5 content-match check working, we have to apply the SAME substitution to
# the local bytes before hashing. If the helper isn't on disk (e.g. on a
# runner where ci/ isn't deployed), define a passthrough stub.
$subPath = if ($mapPath) { Join-Path (Split-Path $mapPath) 'Substitute-Aliases.ps1' } else { $null }
if ($subPath -and (Test-Path $subPath)) {
    . $subPath
    if (Test-AliasSubstitutionActive) {
        Write-Host "  Alias substitution: ACTIVE -- local content will be rewritten before MD5" -ForegroundColor DarkGray
    }
} else {
    function Convert-Aliases { param([byte[]]$ContentBytes) ; ,$ContentBytes }
    function Test-AliasSubstitutionActive { $false }
}

# ============================================================
# RESULT TRACKING
# ============================================================

$results  = [System.Collections.ArrayList]::new()
$passCount = 0
$failCount = 0
$warnCount = 0

# Soft-optional S3 keys: missing = WARN (not a hard failure). These are
# files the runner can boot without -- in particular, the SSH-key
# authorized_keys file for fleet-wide passwordless SSH (AD password auth
# works fine without it).
$Script:SoftOptionalS3Keys = @(
    'tools/openssh/administrators_authorized_keys'
)

function Add-Result {
    param(
        [string]$Category,
        [string]$Target,
        [bool]$Ok,
        [string]$Detail = '',
        # When $Ok is $false: -Severity 'WARN' downgrades the failure to a
        # warning (does not fail the gate, exit code unaffected). Default 'FAIL'
        # preserves the previous strict semantics.
        [ValidateSet('FAIL','WARN')][string]$Severity = 'FAIL'
    )
    if ($Ok) {
        $script:passCount++
        $status = 'PASS'; $color = 'Green'
    } elseif ($Severity -eq 'WARN') {
        $script:warnCount++
        $status = 'WARN'; $color = 'Yellow'
    } else {
        $script:failCount++
        $status = 'FAIL'; $color = 'Red'
    }
    Write-Host "  [$status] " -ForegroundColor $color -NoNewline
    Write-Host "$Category | $Target" -NoNewline
    if ($Detail) { Write-Host " -- $Detail" -ForegroundColor DarkGray } else { Write-Host '' }
    [void]$results.Add([PSCustomObject]@{
        Category = $Category
        Target   = $Target
        Status   = $status
        Detail   = $Detail
    })
}

Write-Host "`n=====================================================" -ForegroundColor Cyan
Write-Host '  DEPENDENCY VALIDATION -- Pre-flight Check' -ForegroundColor Cyan
Write-Host "=====================================================`n" -ForegroundColor Cyan

# ============================================================
# 1. DNS RESOLUTION
# ============================================================

if (-not $SkipDns) {
    Write-Host '[1/3] DNS Resolution' -ForegroundColor Yellow
    Write-Host '-----------------------------------------------------'

    foreach ($entry in $Script:Config.MonitorHosts) {
        $hostName = $entry.Host
        try {
            $addresses = [System.Net.Dns]::GetHostAddresses($hostName)
            $ipList = ($addresses | ForEach-Object { $_.IPAddressToString }) -join ', '
            Add-Result -Category 'DNS' -Target $hostName -Ok $true -Detail $ipList
        }
        catch {
            Add-Result -Category 'DNS' -Target $hostName -Ok $false -Detail $_.Exception.Message
        }
    }
    Write-Host ''
}

# ============================================================
# 2. MinIO S3 ARTIFACT CHECK (HEAD -- no download)
# ============================================================

if (-not $SkipS3) {
    Write-Host '[2/3] MinIO S3 Artifacts (HEAD check)' -ForegroundColor Yellow
    Write-Host '-----------------------------------------------------'

    # Collect all S3 keys from Config
    $allS3Keys = [System.Collections.ArrayList]::new()

    foreach ($kv in $Script:Config.S3Keys.GetEnumerator()) {
        [void]$allS3Keys.Add($kv.Value)
    }
    foreach ($kv in $Script:Config.S3KeysExtra.GetEnumerator()) {
        [void]$allS3Keys.Add($kv.Value)
    }
    foreach ($key in $Script:Config.S3Certs) {
        [void]$allS3Keys.Add($key)
    }
    foreach ($kv in $Script:Config.S3Bootstrap.GetEnumerator()) {
        [void]$allS3Keys.Add($kv.Value)
    }

    $endpoint  = $Script:Config.MinioEndpoint
    $bucket    = $Script:Config.MinioBucket
    $accessKey = $Script:Config.MinioAccessKey
    $secretKey = $Script:Config.MinioSecretKey
    $region    = $Script:Config.MinioRegion

    $uri       = [System.Uri]$endpoint
    $hostHeader = $uri.Host
    if ($uri.Port -ne 443 -and $uri.Port -ne 80) { $hostHeader = "$($uri.Host):$($uri.Port)" }

    function Send-S3Head {
        <#
        .SYNOPSIS  AWS SigV4 HEAD request -- returns status code (200 = exists, 404 = missing).
        #>
        param([string]$Key)

        $now       = [DateTime]::UtcNow
        $dateStamp = $now.ToString('yyyyMMdd')
        $amzDate   = $now.ToString('yyyyMMddTHHmmssZ')

        $encodedKey       = ($Key -split '/' | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
        $canonicalUri     = "/$bucket/$encodedKey"
        $payloadHash      = 'UNSIGNED-PAYLOAD'
        $canonicalHeaders = "host:$hostHeader`nx-amz-content-sha256:$payloadHash`nx-amz-date:$amzDate`n"
        $signedHeaders    = 'host;x-amz-content-sha256;x-amz-date'
        $canonicalRequest = "HEAD`n$canonicalUri`n`n$canonicalHeaders`n$signedHeaders`n$payloadHash"

        $credentialScope = "$dateStamp/$region/s3/aws4_request"
        $canonicalHash   = [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes($canonicalRequest)
            )
        ).Replace('-','').ToLower()

        $stringToSign = "AWS4-HMAC-SHA256`n$amzDate`n$credentialScope`n$canonicalHash"

        $kSecret   = [System.Text.Encoding]::UTF8.GetBytes("AWS4$secretKey")
        $hmac      = New-Object System.Security.Cryptography.HMACSHA256
        $hmac.Key  = $kSecret
        $kDate     = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($dateStamp))
        $hmac.Key  = $kDate
        $kRegion   = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($region))
        $hmac.Key  = $kRegion
        $kService  = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes('s3'))
        $hmac.Key  = $kService
        $kSigning  = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes('aws4_request'))
        $hmac.Key  = $kSigning
        $signature = [System.BitConverter]::ToString(
            $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($stringToSign))
        ).Replace('-','').ToLower()

        $authHeader = "AWS4-HMAC-SHA256 Credential=$accessKey/$credentialScope, SignedHeaders=$signedHeaders, Signature=$signature"
        $url = "$endpoint/$bucket/$Key"

        try {
            $request = [System.Net.HttpWebRequest]::Create($url)
            $request.Method  = 'HEAD'
            $request.Timeout = 10000   # 10 seconds
            $request.Headers.Add('Authorization', $authHeader)
            $request.Headers.Add('x-amz-content-sha256', $payloadHash)
            $request.Headers.Add('x-amz-date', $amzDate)

            $response    = $request.GetResponse()
            $statusCode  = [int]$response.StatusCode
            $contentLen  = $response.ContentLength
            $response.Close()

            $etag = ($response.Headers['ETag'])
            return @{
                StatusCode  = $statusCode
                Size        = $contentLen
                ETag        = $etag
                Error       = ''
            }
        }
        catch [System.Net.WebException] {
            $webEx = $_.Exception
            if ($webEx.Response) {
                $statusCode = [int]$webEx.Response.StatusCode
                $webEx.Response.Close()
                return @{ StatusCode = $statusCode; Size = -1; ETag = $null; Error = "HTTP $statusCode" }
            }
            return @{ StatusCode = 0; Size = -1; ETag = $null; Error = $webEx.Message }
        }
        catch {
            return @{ StatusCode = 0; Size = -1; ETag = $null; Error = $_.Exception.Message }
        }
    }

    # Repo root (where ci/ and lib/ live) -- needed to resolve local paths
    # for the MD5 content-match check.
    $repoRoot = Split-Path $PSScriptRoot -Parent

    foreach ($key in ($allS3Keys | Sort-Object)) {
        $result = Send-S3Head -Key $key
        if ($result.StatusCode -eq 200) {
            $sizeStr = if ($result.Size -ge 1MB) {
                '{0:N1} MB' -f ($result.Size / 1MB)
            } elseif ($result.Size -ge 1KB) {
                '{0:N0} KB' -f ($result.Size / 1KB)
            } else {
                "$($result.Size) B"
            }
            Add-Result -Category 'S3' -Target "$bucket/$key" -Ok $true -Detail $sizeStr

            # --- Content-match check via ETag (S3/MinIO ETag = MD5(content) for
            # single-PUT uploads, which Sync-ToMinio.ps1 always uses).
            # Skip when:
            #   - the S3 key has no corresponding local file in $FileMap
            #     (binary tools uploaded out-of-band via USB),
            #   - the ETag header was missing (unlikely with MinIO),
            #   - the ETag contains "-" indicating a multipart upload
            #     (defensive: opaque hash, can't compare).
            if ($Script:S3KeyToRepoPath.Count -gt 0 -and
                $Script:S3KeyToRepoPath.ContainsKey($key)) {

                $localRel  = $Script:S3KeyToRepoPath[$key]
                $localFull = Join-Path $repoRoot $localRel
                $remoteEtag = $result.ETag
                if ($remoteEtag) {
                    $remoteEtag = $remoteEtag.Trim('"').Trim()
                }

                if (-not (Test-Path $localFull)) {
                    Add-Result -Category 'S3-Content' -Target "$bucket/$key" -Ok $false `
                        -Detail "local file missing: $localRel"
                }
                elseif (-not $remoteEtag) {
                    Add-Result -Category 'S3-Content' -Target "$bucket/$key" -Ok $true `
                        -Detail 'skipped (no ETag header)'
                }
                elseif ($remoteEtag -match '-') {
                    # Multipart upload -- ETag is opaque <md5-of-md5s>-<parts>
                    Add-Result -Category 'S3-Content' -Target "$bucket/$key" -Ok $true `
                        -Detail "skipped (multipart upload, ETag opaque: $remoteEtag)"
                }
                else {
                    # Read the local bytes, apply alias substitution (no-op
                    # when REAL_* env vars are unset), then MD5. Sync-ToMinio
                    # ran the same substitution before upload, so MinIO's
                    # ETag is MD5 over the substituted bytes -- this matches.
                    $localBytes = [System.IO.File]::ReadAllBytes($localFull)
                    $localBytes = Convert-Aliases -ContentBytes $localBytes
                    $md5        = [System.Security.Cryptography.MD5]::Create()
                    $localMd5   = [System.BitConverter]::ToString($md5.ComputeHash($localBytes)).Replace('-','').ToLower()
                    if ($localMd5 -eq $remoteEtag.ToLower()) {
                        Add-Result -Category 'S3-Content' -Target "$bucket/$key" -Ok $true `
                            -Detail "MD5=$($localMd5.Substring(0,12))..."
                    } else {
                        Add-Result -Category 'S3-Content' -Target "$bucket/$key" -Ok $false `
                            -Detail "MD5 mismatch: local=$($localMd5.Substring(0,12))... remote=$($remoteEtag.Substring(0,[Math]::Min(12,$remoteEtag.Length)))..."
                    }
                }
            }
        }
        else {
            $severity = if ($Script:SoftOptionalS3Keys -contains $key) { 'WARN' } else { 'FAIL' }
            $detail   = if ($severity -eq 'WARN') { "$($result.Error) (optional -- can be skipped)" } else { $result.Error }
            Add-Result -Category 'S3' -Target "$bucket/$key" -Ok $false -Detail $detail -Severity $severity
        }
    }
    Write-Host ''
}

# ============================================================
# 3. HARBOR IMAGE CHECK (Registry API v2 -- no pull)
# ============================================================

if (-not $SkipHarbor) {
    Write-Host '[3/3] Harbor Images (manifest check)' -ForegroundColor Yellow
    Write-Host '-----------------------------------------------------'

    $harborScheme = 'https'
    $harborBase   = "${harborScheme}://$($Script:Config.HarborUrl)"

    # Build Basic auth header if credentials are set
    $authHeaders = @{}
    if ($Script:Config.HarborUser -and $Script:Config.HarborPass) {
        $pair  = "$($Script:Config.HarborUser):$($Script:Config.HarborPass)"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
        $b64   = [System.Convert]::ToBase64String($bytes)
        $authHeaders['Authorization'] = "Basic $b64"
    }

    # Test registry v2 API is reachable
    $v2Url = "$harborBase/v2/"
    $registryUp = $false
    try {
        $req = [System.Net.HttpWebRequest]::Create($v2Url)
        $req.Method  = 'GET'
        $req.Timeout = 10000
        foreach ($h in $authHeaders.GetEnumerator()) { $req.Headers.Add($h.Key, $h.Value) }
        $resp = $req.GetResponse()
        $registryUp = ([int]$resp.StatusCode -eq 200)
        $resp.Close()
    }
    catch [System.Net.WebException] {
        $webEx = $_.Exception
        if ($webEx.Response) {
            $code = [int]$webEx.Response.StatusCode
            # 401 means registry is up but needs auth -- still reachable
            $registryUp = ($code -eq 401)
            $webEx.Response.Close()
        }
    }
    catch {}

    Add-Result -Category 'Harbor' -Target "$($Script:Config.HarborUrl)/v2/" -Ok $registryUp `
        -Detail $(if ($registryUp) { 'Registry API reachable' } else { 'Registry API unreachable' })

    if ($registryUp) {
        foreach ($image in $Script:Config.PrePullImages) {
            # Parse: harbor.kayhut.com/golden-image/servercore:ltsc2019
            #   -> registry = harbor.kayhut.com
            #   -> repo     = golden-image/servercore
            #   -> tag      = ltsc2019
            $withoutRegistry = $image -replace "^$([regex]::Escape($Script:Config.HarborUrl))/", ''
            if ($withoutRegistry -match '^(.+):([^:]+)$') {
                $repo = $Matches[1]
                $tag  = $Matches[2]
            } else {
                $repo = $withoutRegistry
                $tag  = 'latest'
            }

            $manifestUrl = "$harborBase/v2/$repo/manifests/$tag"
            $imageOk = $false
            $detail  = ''

            try {
                $req = [System.Net.HttpWebRequest]::Create($manifestUrl)
                $req.Method  = 'HEAD'
                $req.Timeout = 15000
                $req.Accept  = 'application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json'
                foreach ($h in $authHeaders.GetEnumerator()) { $req.Headers.Add($h.Key, $h.Value) }

                $resp = $req.GetResponse()
                $imageOk = ([int]$resp.StatusCode -eq 200)
                $contentLen = $resp.ContentLength
                $digest = $resp.Headers['Docker-Content-Digest']
                $resp.Close()

                if ($digest) {
                    $shortDigest = $digest.Substring(0, [Math]::Min(19, $digest.Length))
                    $detail = "digest=$shortDigest"
                } else {
                    $detail = 'manifest exists'
                }
            }
            catch [System.Net.WebException] {
                $webEx = $_.Exception
                if ($webEx.Response) {
                    $code = [int]$webEx.Response.StatusCode
                    $detail = "HTTP $code"
                    $webEx.Response.Close()
                    # Some registries (Harbor in particular) reject HEAD with 401 even
                    # for anonymously-readable repos -- you only see the 200 over GET.
                    # Other registries return 405 (Method Not Allowed) for HEAD on
                    # manifests. Try GET in either case before giving up.
                    if ($code -eq 405 -or $code -eq 401) {
                        try {
                            $req2 = [System.Net.HttpWebRequest]::Create($manifestUrl)
                            $req2.Method  = 'GET'
                            $req2.Timeout = 15000
                            $req2.Accept  = 'application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json'
                            foreach ($h in $authHeaders.GetEnumerator()) { $req2.Headers.Add($h.Key, $h.Value) }
                            $resp2 = $req2.GetResponse()
                            $imageOk = ([int]$resp2.StatusCode -eq 200)
                            $digest2 = $resp2.Headers['Docker-Content-Digest']
                            $resp2.Close()
                            $detail = if ($digest2) {
                                "digest=$($digest2.Substring(0, [Math]::Min(19, $digest2.Length))) (GET fallback after $code)"
                            } else { "manifest exists (GET fallback after HEAD $code)" }
                        }
                        catch {
                            $detail = "GET fallback failed: $($_.Exception.Message)"
                        }
                    }
                } else {
                    $detail = $webEx.Message
                }
            }
            catch {
                $detail = $_.Exception.Message
            }

            Add-Result -Category 'Harbor' -Target $image -Ok $imageOk -Detail $detail
        }
    } else {
        # Registry unreachable -- mark all images as failed
        foreach ($image in $Script:Config.PrePullImages) {
            Add-Result -Category 'Harbor' -Target $image -Ok $false -Detail 'Skipped -- registry unreachable'
        }
    }
    Write-Host ''
}

# ============================================================
# SUMMARY
# ============================================================

$total = $passCount + $failCount + $warnCount

Write-Host '=====================================================' -ForegroundColor Cyan
if ($failCount -eq 0) {
    if ($warnCount -gt 0) {
        Write-Host "  ALL CRITICAL CHECKS PASSED ($passCount pass, $warnCount warn)" -ForegroundColor Green
    } else {
        Write-Host "  ALL $total CHECKS PASSED" -ForegroundColor Green
    }
} else {
    Write-Host "  $failCount of $total CHECKS FAILED ($warnCount warnings)" -ForegroundColor Red
    Write-Host ''
    Write-Host '  Failed items:' -ForegroundColor Red
    $results | Where-Object { $_.Status -eq 'FAIL' } | ForEach-Object {
        Write-Host "    - $($_.Category) | $($_.Target) -- $($_.Detail)" -ForegroundColor Red
    }
}
if ($warnCount -gt 0) {
    Write-Host ''
    Write-Host '  Warnings (not failing the gate):' -ForegroundColor Yellow
    $results | Where-Object { $_.Status -eq 'WARN' } | ForEach-Object {
        Write-Host "    - $($_.Category) | $($_.Target) -- $($_.Detail)" -ForegroundColor Yellow
    }
}
Write-Host "=====================================================`n" -ForegroundColor Cyan

# Return structured results for pipeline use
$summary = [PSCustomObject]@{
    Total    = $total
    Passed   = $passCount
    Failed   = $failCount
    Warned   = $warnCount
    Results  = $results
}

# Write to Event Log if running during install
try {
    if ($failCount -eq 0) {
        Write-EventLog -LogName Application -Source 'GitLabRunner' -EventId 9030 -EntryType Information `
            -Message "Dependency validation: ALL $total checks passed."
    } else {
        $failedList = ($results | Where-Object { $_.Status -eq 'FAIL' } |
            ForEach-Object { "$($_.Category): $($_.Target)" }) -join "`n"
        Write-EventLog -LogName Application -Source 'GitLabRunner' -EventId 9031 -EntryType Warning `
            -Message "Dependency validation: $failCount of $total checks FAILED.`n$failedList"
    }
} catch {
    # Event log source may not exist yet on a fresh VM -- that's fine
}

Write-Output $summary

exit $(if ($failCount -eq 0) { 0 } else { 1 })
