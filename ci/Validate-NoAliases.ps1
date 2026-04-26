<#
.SYNOPSIS
    Validate that no public aliases remain in the internal codebase.

.DESCRIPTION
    Scans ALL files (scripts, config, docs, markdown) for aliases that
    belong only in the public GitHub repo. Checks every line including
    comments, docstrings, and markdown content.

    Hostname aliases:
      harbor.kayhut.com, gitlab.kayhut.com, kayhut-minio.com, be1.kayhut.com

    Project name alias:
      Terrabookra  (internal name: Runners-Infra)

    Exits non-zero if any alias is found. Skips only the ci/ directory
    (this validator itself references aliases as patterns).

.PARAMETER Path
    Directory to scan (default: repo root)

.NOTES
    File: ci/Validate-NoAliases.ps1
#>
param(
    [string]$Path = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'

$AliasPatterns = @(
    @{ Pattern = 'harbor\.kayhut\.com';  Label = 'harbor.kayhut.com'  },
    @{ Pattern = 'gitlab\.kayhut\.com';  Label = 'gitlab.kayhut.com'  },
    @{ Pattern = 'kayhut-minio\.com';    Label = 'kayhut-minio.com'   },
    @{ Pattern = 'be1\.kayhut\.com';     Label = 'be1.kayhut.com'     },
    @{ Pattern = '[Tt]errabookra';       Label = 'Terrabookra -> Runners-Infra' }
)

$Extensions = @('*.ps1','*.jsonc','*.json','*.yml','*.yaml','*.toml','*.md','*.txt')

Write-Output '============================================'
Write-Output 'Validate-NoAliases -- scanning for public aliases'
Write-Output "Path: $Path"
Write-Output '============================================'

$found = 0

foreach ($file in (Get-ChildItem -Path $Path -Recurse -Include $Extensions -File)) {
    $relPath = $file.FullName.Substring($Path.Length).TrimStart('\','/')

    # Skip ci/ directory (this script references aliases as patterns)
    if ($relPath -like 'ci\*' -or $relPath -like 'ci/*') { continue }

    $lines = Get-Content $file.FullName -ErrorAction SilentlyContinue
    if (-not $lines) { continue }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($alias in $AliasPatterns) {
            if ($lines[$i] -match $alias.Pattern) {
                Write-Output "  $relPath`:$($i+1) -> $($alias.Label)"
                $found++
                break
            }
        }
    }
}

Write-Output ''
Write-Output '============================================'

if ($found -gt 0) {
    Write-Output "FAILED: $found alias(es) found."
    Write-Output '  Replace all hostnames and Terrabookra references before pushing.'
    exit 1
}

Write-Output 'PASSED: no aliases found'
exit 0
