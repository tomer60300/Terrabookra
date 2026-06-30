<#
.SYNOPSIS
  Production preflight for the infra_tf / Aria catalog deployment path.

.DESCRIPTION
  Runs before terraform apply. It intentionally checks the boring failure modes
  first: exact Terraform runtime, offline provider mirror, CLI config, env-only
  refresh token, Terraform 1.0.5-compatible syntax, Aria reachability, and
  string-only vm_inputs.

  The refresh token is never printed. Do not pass it on the command line; set
  TF_VAR_vra_refresh_token in the process or CI masked/protected environment.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Preflight is a command-line gate; console logging avoids polluting function return streams.')]
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$TerraformDir,
    [string]$ModuleDir,
    [string]$TerraformExe,
    [string]$ProviderMirror,
    [string]$RequiredTerraformVersion = '1.0.5',
    [string]$RequiredProviderVersion = '0.17.2',
    [string[]]$RequiredVmInputKeys = @(),
    [switch]$SkipAriaApi
)

$ErrorActionPreference = 'Stop'
$Script:FailCount = 0
$Script:WarnCount = 0

if (-not $RepoRoot) {
    if ($PSScriptRoot) { $RepoRoot = Split-Path $PSScriptRoot -Parent }
    else { $RepoRoot = (Get-Location).ProviderPath }
}
if (-not $TerraformDir)  { $TerraformDir  = Join-Path $RepoRoot 'terraform' }
if (-not $ModuleDir)     { $ModuleDir     = Join-Path $RepoRoot 'module' }
if (-not $TerraformExe)  { $TerraformExe  = Join-Path $RepoRoot 'dist\bin\terraform.exe' }
if (-not $ProviderMirror){ $ProviderMirror = Join-Path $RepoRoot 'dist\providers' }

function Write-Result {
    param([string]$Status, [string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    [Console]::WriteLine("[$ts] [$Status] [aria-preflight] $Message")
}

function Pass { param([string]$Message) Write-Result 'PASS' $Message }
function Warn { param([string]$Message) $Script:WarnCount++; Write-Result 'WARN' $Message }
function Fail { param([string]$Message) $Script:FailCount++; Write-Result 'FAIL' $Message }

function Get-TextFileSet {
    param([string[]]$Roots, [string[]]$Patterns)
    $files = @()
    foreach ($root in $Roots) {
        if (Test-Path -LiteralPath $root) {
            foreach ($pattern in $Patterns) {
                $files += Get-ChildItem -LiteralPath $root -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue
            }
        }
    }
    return @($files | Sort-Object -Property FullName -Unique)
}

function Get-TfVarFileValue {
    param([string]$Name)
    $files = @(Get-TextFileSet -Roots @($TerraformDir) -Patterns @('*.tfvars', '*.tfvars.json'))
    $files += @(Get-ChildItem -LiteralPath $TerraformDir -File -Filter 'terraform.tfvars' -ErrorAction SilentlyContinue)
    foreach ($f in @($files | Sort-Object -Property FullName -Unique)) {
        $lines = Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue
        foreach ($line in $lines) {
            if ($line -match "^\s*$([regex]::Escape($Name))\s*=\s*`"([^`"]*)`"") { return $Matches[1] }
            if ($line -match "^\s*$([regex]::Escape($Name))\s*=\s*(true|false)\s*(#.*)?$") { return $Matches[1] }
        }
    }
    return $null
}

function Enable-InsecureTlsIfNeeded {
    param([bool]$Enable)
    if (-not $Enable) { return }
    if (-not ([System.Management.Automation.PSTypeName]'AriaPreflightTrustAllCerts').Type) {
        Add-Type -TypeDefinition @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public class AriaPreflightTrustAllCerts {
    public static void Enable() {
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        ServicePointManager.ServerCertificateValidationCallback =
            delegate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors sslPolicyErrors) { return true; };
    }
}
"@
    }
    [AriaPreflightTrustAllCerts]::Enable()
}

function Invoke-AriaJson {
    param(
        [string]$Method,
        [string]$Uri,
        [string]$Body
    )
    $headers = @{ Accept = 'application/json' }
    if ($Body) {
        return Invoke-WebRequest -UseBasicParsing -Method $Method -Uri $Uri -Headers $headers -ContentType 'application/json' -Body $Body -TimeoutSec 20
    }
    return Invoke-WebRequest -UseBasicParsing -Method $Method -Uri $Uri -Headers $headers -TimeoutSec 20
}

Write-Result 'INFO' "repo=$RepoRoot terraform=$TerraformDir module=$ModuleDir"

# 1. Exact bundled Terraform runtime.
if (Test-Path -LiteralPath $TerraformExe) {
    $versionText = & $TerraformExe version 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $versionText -match "Terraform v$([regex]::Escape($RequiredTerraformVersion))(\s|$)") {
        Pass "Terraform binary is exactly $RequiredTerraformVersion ($TerraformExe)"
    } else {
        Fail "Terraform binary exists but is not exactly $RequiredTerraformVersion. Output: $($versionText.Trim())"
    }
} else {
    Fail "Terraform binary missing: $TerraformExe"
}

# 2. TF_CLI_CONFIG_FILE must point to the offline mirror config.
$cliConfig = [Environment]::GetEnvironmentVariable('TF_CLI_CONFIG_FILE', 'Process')
if (-not $cliConfig) {
    Fail 'TF_CLI_CONFIG_FILE is not set. Point it at terraform\terraform.rc before init/apply.'
} elseif (-not (Test-Path -LiteralPath $cliConfig)) {
    Fail "TF_CLI_CONFIG_FILE points to a missing file: $cliConfig"
} else {
    $cliText = Get-Content -LiteralPath $cliConfig -Raw
    if ($cliText -match 'provider_installation' -and $cliText -match 'filesystem_mirror' -and $cliText -match 'vmware/vra') {
        Pass "TF_CLI_CONFIG_FILE uses a vmware/vra filesystem mirror ($cliConfig)"
    } else {
        Fail "TF_CLI_CONFIG_FILE does not configure a vmware/vra filesystem mirror: $cliConfig"
    }
}

# 3. Provider mirror contents.
if (Test-Path -LiteralPath $ProviderMirror) {
    $providerFiles = @(Get-ChildItem -LiteralPath $ProviderMirror -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'terraform-provider-vra' -and $_.FullName -match [regex]::Escape($RequiredProviderVersion) })
    $windowsProvider = @($providerFiles | Where-Object { $_.FullName -match 'windows_amd64' -or $_.Name -match 'windows_amd64' })
    if ($providerFiles.Count -gt 0) { Pass "vmware/vra $RequiredProviderVersion found in provider mirror" }
    else { Fail "vmware/vra $RequiredProviderVersion not found under $ProviderMirror" }
    if ($windowsProvider.Count -gt 0) { Pass 'provider mirror includes windows_amd64 package for vmware/vra' }
    else { Fail 'provider mirror does not show a windows_amd64 vmware/vra package' }
} else {
    Fail "Provider mirror missing: $ProviderMirror"
}

# 4. Lock file must be for vmware/vra, not the old vSphere provider.
$lockPath = Join-Path $TerraformDir '.terraform.lock.hcl'
if (Test-Path -LiteralPath $lockPath) {
    $lockText = Get-Content -LiteralPath $lockPath -Raw
    if ($lockText -match 'registry\.terraform\.io/vmware/vra' -and $lockText -match "version\s*=\s*`"$([regex]::Escape($RequiredProviderVersion))`"") {
        Pass ".terraform.lock.hcl pins vmware/vra $RequiredProviderVersion"
    } else {
        Fail ".terraform.lock.hcl does not pin registry.terraform.io/vmware/vra $RequiredProviderVersion"
    }
    if ($lockText -match 'hashicorp/vsphere') {
        Fail '.terraform.lock.hcl still contains hashicorp/vsphere'
    }
} else {
    Fail "Missing lock file: $lockPath"
}

# 5. Refresh token source discipline.
$tfVarRefresh = [Environment]::GetEnvironmentVariable('TF_VAR_vra_refresh_token', 'Process')
$directRefresh = [Environment]::GetEnvironmentVariable('VRA_REFRESH_TOKEN', 'Process')
if ($tfVarRefresh) { Pass 'TF_VAR_vra_refresh_token is present (value redacted)' }
else { Fail 'TF_VAR_vra_refresh_token is missing. Do not use tfvars or CLI args for the refresh token.' }
if ($directRefresh) { Fail 'VRA_REFRESH_TOKEN is set. This project requires TF_VAR_vra_refresh_token only.' }

$secretHits = @()
$varFiles = @(Get-TextFileSet -Roots @($TerraformDir) -Patterns @('*.tfvars', '*.tfvars.json'))
$varFiles += @(Get-ChildItem -LiteralPath $TerraformDir -File -Filter 'terraform.tfvars' -ErrorAction SilentlyContinue)
foreach ($f in @($varFiles | Sort-Object -Property FullName -Unique)) {
    $txt = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
    if ($txt -match '(?im)^\s*(vra_)?refresh_token\s*=') { $secretHits += $f.FullName }
}
if ($secretHits.Count -eq 0) { Pass 'refresh token is absent from tfvars files' }
else { Fail "refresh token-like assignment found in tfvars: $($secretHits -join ', ')" }

# 6. Terraform code must stay on Aria catalog path and 1.0.5-safe syntax.
$tfFiles = Get-TextFileSet -Roots @($TerraformDir, $ModuleDir) -Patterns @('*.tf')
$tfText = ($tfFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
if ($tfText -match 'hashicorp/vsphere|vsphere_|vcenter') { Fail 'Terraform/module code still contains direct vCenter/vSphere references.' }
else { Pass 'Terraform/module code has no direct vCenter/vSphere references' }
if ($tfText -match 'optional\s*\(') { Fail 'Terraform/module code uses optional(...) object attributes, unsupported by Terraform 1.0.5.' }
else { Pass 'Terraform/module code avoids optional(...) object attributes' }
if ($tfText -match 'endpoints\s*\{' -or $tfText -match 'use_path_style') { Fail 'Terraform backend code uses unsupported newer S3 backend syntax.' }
else { Pass 'No unsupported S3 backend endpoints{} or use_path_style syntax found' }
if ($tfText -match 'vra_deployment' -and $tfText -match 'vra_catalog_item' -and $tfText -match 'vra_project') {
    Pass 'Terraform uses vra_deployment with catalog item and project data sources'
} else {
    Fail 'Terraform does not contain the required vra_deployment/catalog/project path'
}

# 7. vm_inputs must be present and string-looking in tfvars when tfvars are used.
$inputKeys = New-Object System.Collections.Generic.HashSet[string]
$inputFailures = @()
foreach ($f in @($varFiles | Sort-Object -Property FullName -Unique)) {
    $lines = Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue
    $inside = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*vm_inputs\s*=\s*\{') { $inside = $true; continue }
        if ($inside -and $line -match '^\s*\}') { $inside = $false; continue }
        if ($inside -and $line -match '^\s*([A-Za-z0-9_.-]+)\s*=\s*(.+?)\s*(#.*)?$') {
            $key = $Matches[1]
            $value = $Matches[2].Trim()
            [void]$inputKeys.Add($key)
            if ($value -notmatch '^"([^"]*)"$') {
                $inputFailures += "$($f.FullName): vm_inputs.$key must be a quoted string"
            }
        }
    }
}
if ($inputFailures.Count -eq 0) { Pass 'vm_inputs values in tfvars are quoted strings' }
else { foreach ($failure in $inputFailures) { Fail $failure } }
if ($RequiredVmInputKeys.Count -gt 0) {
    foreach ($key in $RequiredVmInputKeys) {
        if ($inputKeys.Contains($key)) { Pass "required vm_inputs key present: $key" }
        else { Fail "required vm_inputs key missing from tfvars: $key" }
    }
}

# 8. Active S3 backend syntax, if enabled.
$backendPath = Join-Path $TerraformDir 'backend.tf'
if (Test-Path -LiteralPath $backendPath) {
    $backendText = Get-Content -LiteralPath $backendPath -Raw
    if ($backendText -match 'backend\s+"s3"' -and $backendText -notmatch 'force_path_style\s*=\s*true') {
        Fail 'Active S3 backend is missing force_path_style = true'
    } else {
        Pass 'Active backend syntax check passed'
    }
} else {
    Warn 'No active backend.tf found; local backend is acceptable only for local dry-runs, not production apply.'
}

# 9. Aria reachability and sanitized refresh-token validation.
if ($SkipAriaApi) {
    Warn 'Skipping Aria API checks by request.'
} else {
    $vraUrl = [Environment]::GetEnvironmentVariable('TF_VAR_vra_url', 'Process')
    if (-not $vraUrl) { $vraUrl = Get-TfVarFileValue -Name 'vra_url' }
    $vraInsecureRaw = [Environment]::GetEnvironmentVariable('TF_VAR_vra_insecure', 'Process')
    if (-not $vraInsecureRaw) { $vraInsecureRaw = Get-TfVarFileValue -Name 'vra_insecure' }
    $vraInsecure = ($vraInsecureRaw -match '^(?i:true)$')

    if (-not $vraUrl) {
        Fail 'vra_url not found in TF_VAR_vra_url or tfvars.'
    } else {
        Enable-InsecureTlsIfNeeded -Enable $vraInsecure
        $base = $vraUrl.TrimEnd('/')
        try {
            $about = Invoke-AriaJson -Method GET -Uri "$base/iaas/api/about"
            if ($about.StatusCode -ge 200 -and $about.StatusCode -lt 300) { Pass "Aria IaaS about endpoint reachable ($base)" }
            else { Fail "Aria IaaS about endpoint returned HTTP $($about.StatusCode)" }
        } catch {
            Fail "Aria IaaS about endpoint unreachable: $($_.Exception.Message)"
        }

        if ($tfVarRefresh) {
            $body = (@{ refreshToken = $tfVarRefresh } | ConvertTo-Json -Compress)
            $tokenOk = $false
            $tokenErrors = @()
            foreach ($path in @('/iaas/api/login', '/csp/gateway/am/api/auth/api-tokens/authorize')) {
                try {
                    $resp = Invoke-AriaJson -Method POST -Uri "$base$path" -Body $body
                    if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) { $tokenOk = $true; break }
                    $tokenErrors += "$path HTTP $($resp.StatusCode)"
                } catch {
                    $tokenErrors += "$path $($_.Exception.Message)"
                }
            }
            if ($tokenOk) { Pass 'Aria refresh token validation succeeded (token redacted)' }
            else { Fail "Aria refresh token validation failed (token redacted): $($tokenErrors -join '; ')" }
        }
    }
}

Write-Result 'INFO' "preflight complete: failures=$Script:FailCount warnings=$Script:WarnCount"
if ($Script:FailCount -gt 0) { exit 1 }
exit 0
