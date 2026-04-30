<#
.SYNOPSIS
    Substitute kayhut.com / Terrabookra aliases with real values from CI env vars.

.DESCRIPTION
    The public GitHub repo (`tomer60300/Terrabookra`) intentionally contains
    placeholder aliases like `harbor.kayhut.com`, `kayhut-minio.com`,
    `Terrabookra`, etc. They live in committed files and are enforced by
    `ci/Validate-NoAliases.ps1` so real internal hostnames never leak to the
    public side.

    For the internal GitLab CI to actually publish working files to MinIO, the
    aliases need to be replaced with real hostnames AT SYNC TIME. This module
    is the substitution engine, sourced by:

      - ci/Sync-ToMinio.ps1            -- substitutes file content in memory
                                          before the AWS SigV4 PUT, so MinIO
                                          stores real hostnames.
      - validation/Test-Dependencies.ps1 -- substitutes local file content in
                                            memory before MD5'ing, so the
                                            MD5 == ETag content-match check
                                            still works (both sides ran the
                                            same substitution).

    Substitution is OPT-IN via environment variables. If a REAL_* env var
    isn't set, the corresponding alias passes through unchanged. That means:
      - Public-side users without CI vars see zero behaviour change.
      - Internal GitLab CI sets REAL_* vars (Settings > CI/CD > Variables,
        masked + protected) and substitution kicks in automatically.

    Substitution rules:
      'harbor.kayhut.com'   ->  $env:REAL_HARBOR_HOST
      'gitlab.kayhut.com'   ->  $env:REAL_GITLAB_HOST
      'kayhut-minio.com'    ->  $env:REAL_MINIO_HOST
      'be1.kayhut.com'      ->  $env:REAL_BE1_HOST
      'Terrabookra'         ->  $env:REAL_PROJECT_NAME
      'terrabookra'         ->  $env:REAL_PROJECT_NAME (lowercased)

    Binary files (detected via NUL byte presence) are returned unchanged.
    Text files that don't contain any of the configured aliases are also
    returned unchanged (avoids byte-level diff from UTF-8 round-trip).

.NOTES
    File: ci/Substitute-Aliases.ps1
#>

# Substitution rule table. Adding a new alias = one row here.
$Script:AliasRules = @(
    @{ Alias = 'harbor.kayhut.com';  Env = 'REAL_HARBOR_HOST'  ; Mode = 'verbatim' }
    @{ Alias = 'gitlab.kayhut.com';  Env = 'REAL_GITLAB_HOST'  ; Mode = 'verbatim' }
    @{ Alias = 'kayhut-minio.com';   Env = 'REAL_MINIO_HOST'   ; Mode = 'verbatim' }
    @{ Alias = 'be1.kayhut.com';     Env = 'REAL_BE1_HOST'     ; Mode = 'verbatim' }
    @{ Alias = 'Terrabookra';        Env = 'REAL_PROJECT_NAME' ; Mode = 'verbatim' }
    # Lowercase variant of the project name (e.g. inside log strings, paths)
    @{ Alias = 'terrabookra';        Env = 'REAL_PROJECT_NAME' ; Mode = 'lower'    }
)

function Test-AliasSubstitutionActive {
    <#
    .SYNOPSIS
        Returns $true if any REAL_* env var is set (substitution will fire).
    #>
    foreach ($r in $Script:AliasRules) {
        if ([Environment]::GetEnvironmentVariable($r.Env)) { return $true }
    }
    return $false
}

function Get-ActiveSubstitutions {
    <#
    .SYNOPSIS
        Returns the active alias->real pairs for diagnostic logging.
        Real values are returned masked (first 3 chars + ***) for safety.
    #>
    $active = @()
    foreach ($r in $Script:AliasRules) {
        $real = [Environment]::GetEnvironmentVariable($r.Env)
        if ($real) {
            $masked = if ($real.Length -gt 3) { $real.Substring(0,3) + '***' } else { '***' }
            $active += [PSCustomObject]@{
                Alias = $r.Alias
                Env   = $r.Env
                Real  = $masked
            }
        }
    }
    return ,$active
}

function Convert-Aliases {
    <#
    .SYNOPSIS
        Replace public aliases with real values from REAL_* env vars.
    .PARAMETER ContentBytes
        Raw file bytes. Binary content (containing NUL) is returned unchanged.
    .OUTPUTS
        [byte[]] -- substituted bytes, or the input bytes unchanged when no
                   substitution applied.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$ContentBytes
    )

    if ($ContentBytes.Length -eq 0) { return $ContentBytes }

    # Skip binary content.
    if ($ContentBytes -contains 0) { return $ContentBytes }

    # Decode UTF-8. If the file isn't valid UTF-8, fall through unchanged.
    try {
        $text = [System.Text.Encoding]::UTF8.GetString($ContentBytes)
    } catch {
        return $ContentBytes
    }

    $changed = $false
    foreach ($r in $Script:AliasRules) {
        $real = [Environment]::GetEnvironmentVariable($r.Env)
        if (-not $real) { continue }

        $replacement = if ($r.Mode -eq 'lower') { $real.ToLower() } else { $real }
        if ($text.Contains($r.Alias)) {
            $text = $text.Replace($r.Alias, $replacement)
            $changed = $true
        }
    }

    if (-not $changed) { return $ContentBytes }

    return [System.Text.Encoding]::UTF8.GetBytes($text)
}
