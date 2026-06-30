<#
.SYNOPSIS
    Enforce the alias-by-resolution invariant (decision 3): lib/Config.ps1 must
    keep the *.kayhut.com host ALIASES as defaults and read $env:REAL_* overrides
    -- never hardcode a real internal FQDN.

.DESCRIPTION
    Decision (3) retired byte-substitution. The host aliases now STAY in source on
    BOTH legs (public + internal) and resolve by name (hosts/DNS) or via the
    $env:REAL_* overrides at runtime. The risk is no longer "an alias leaked into
    the internal repo" (aliases are correct everywhere) but the inverse: someone
    replaces an alias default with a real internal FQDN, leaking real infra into
    the public source and breaking the env-override mechanism.

    This validator asserts the invariant holds: each expected alias appears as a
    default in lib/Config.ps1, AND each is wrapped in an $env:REAL_* override.
    It is GREEN on correct source and fails loudly if an alias is removed or a
    real host is hardcoded in its place.

    (The previous "fail if any *.kayhut.com appears" rule was correct only under
    the old substitution model; it is inverted here.)

.PARAMETER ConfigPath
    Path to lib/Config.ps1 (default: resolved from repo root).

.NOTES
    File: ci/Validate-NoAliases.ps1
#>
param(
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/Config.ps1')
)

$ErrorActionPreference = 'Stop'

# Each host alias that must remain a default in Config.ps1, paired with the
# $env:REAL_* override it must be guarded by.
$Invariants = @(
    @{ Alias = 'gitlab.kayhut.com'; Env = 'REAL_GITLAB_HOST'      },
    @{ Alias = 'artifactory-prod';  Env = 'REAL_ARTIFACTORY_HOST' }
)
# MinIO is retired, so its alias no longer lives in Config -- it is not asserted.
# The GitLab registry alias derives from $_gitLabHost, so REAL_GITLAB_HOST covers it.

Write-Output '============================================'
Write-Output 'Validate-NoAliases -- alias-by-resolution invariant (decision 3)'
Write-Output "Config: $ConfigPath"
Write-Output '============================================'

if (-not (Test-Path $ConfigPath)) {
    Write-Output "FAILED: Config not found: $ConfigPath"
    exit 1
}
$config = Get-Content $ConfigPath -Raw

$violations = 0
foreach ($inv in $Invariants) {
    $hasAlias = $config -match [regex]::Escape($inv.Alias)
    $hasEnv   = $config -match [regex]::Escape("`$env:$($inv.Env)")
    if ($hasAlias -and $hasEnv) {
        Write-Output "  [OK]   $($inv.Alias)  (default + `$env:$($inv.Env) override present)"
    } else {
        if (-not $hasAlias) { Write-Output "  [FAIL] alias '$($inv.Alias)' missing -- a real FQDN may have been hardcoded" }
        if (-not $hasEnv)   { Write-Output "  [FAIL] `$env:$($inv.Env) override missing for '$($inv.Alias)'" }
        $violations++
    }
}

Write-Output ''
Write-Output '============================================'

if ($violations -gt 0) {
    Write-Output "FAILED: $violations alias-invariant violation(s)."
    Write-Output '  Keep the *.kayhut.com alias as the default and read $env:REAL_* -- do not hardcode real hosts.'
    exit 1
}

Write-Output 'PASSED: alias-by-resolution invariant holds'
exit 0
