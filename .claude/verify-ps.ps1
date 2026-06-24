<#
.SYNOPSIS
  Static verification for a single PowerShell script using the Windows
  PowerShell 5.1 engine. The safety net that replaces eyeballing .ps1 edits.

.DESCRIPTION
  On the public dev leg there is no air-gapped infra to run against, so this is
  static only:
    (a) Parses the file with the in-process PS 5.1 language parser
        ([System.Management.Automation.Language.Parser]::ParseFile). ANY parse
        error fails the run — this is what catches stray quotes, unbalanced
        braces, and PS7-only syntax that 5.1 cannot parse.
    (b) Runs PSScriptAnalyzer (-Severity Warning,Error) and surfaces findings.

  Exit code is non-zero on ANY parse error or ANY Error-severity finding.
  Warnings are reported but do NOT fail the run.

  Run this on Windows PowerShell 5.1 (powershell.exe), NOT pwsh — running it on
  the 5.1 engine is the whole point: PS7-only syntax is rejected here, not
  silently accepted.

.PARAMETER Path
  Path to the .ps1 file to verify.

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .claude\verify-ps.ps1 -Path phases\Phase1-SystemPrep.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    Write-Warning ("verify-ps is meant to run on Windows PowerShell 5.1 (Desktop). Current: {0} {1}. PS7-only syntax may pass that 5.1 would reject." -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
}

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "verify-ps: file not found: $Path"
    exit 2
}
$resolved = (Resolve-Path -LiteralPath $Path).ProviderPath

Write-Host "verify-ps: $resolved"
Write-Host ("  engine: PowerShell {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)

$failed = $false

# --- (a) Parse with the PS 5.1 engine ---------------------------------------
$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($resolved, [ref]$tokens, [ref]$parseErrors)
$parseErrors = @($parseErrors)

if ($parseErrors.Count -gt 0) {
    $failed = $true
    Write-Host ""
    Write-Host ("PARSE ERRORS ({0}):" -f $parseErrors.Count)
    foreach ($e in $parseErrors) {
        Write-Host ("  {0}:{1}:{2}  {3}" -f $resolved, $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message)
    }
} else {
    Write-Host "  parse: OK"
}

# --- (b) PSScriptAnalyzer ----------------------------------------------------
Import-Module PSScriptAnalyzer -ErrorAction Stop
$findings = @(Invoke-ScriptAnalyzer -Path $resolved -Severity Warning, Error)
$errorFindings = @($findings | Where-Object { $_.Severity -eq 'Error' })
$warnFindings  = @($findings | Where-Object { $_.Severity -eq 'Warning' })

if ($findings.Count -gt 0) {
    Write-Host ""
    Write-Host ("PSScriptAnalyzer findings ({0}):" -f $findings.Count)
    foreach ($f in ($findings | Sort-Object Line)) {
        Write-Host ("  {0}:{1}  [{2}] {3} - {4}" -f $resolved, $f.Line, $f.Severity, $f.RuleName, $f.Message)
    }
} else {
    Write-Host "  analyzer: clean"
}

if ($errorFindings.Count -gt 0) { $failed = $true }

Write-Host ""
if ($failed) {
    Write-Host ("RESULT: FAIL  ({0} parse error(s), {1} analyzer error(s), {2} warning(s))" -f $parseErrors.Count, $errorFindings.Count, $warnFindings.Count)
    exit 1
}
Write-Host ("RESULT: PASS  ({0} warning(s))" -f $warnFindings.Count)
exit 0
