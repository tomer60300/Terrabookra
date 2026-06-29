#!/usr/bin/env pwsh
# Dev-leg verification driver. Runs the logic + transfer suites and reports.
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$rc = 0
foreach ($t in @('logic-tests.ps1', 'transfer-roundtrip.ps1')) {
    Write-Host "`n########## $t ##########"
    pwsh -NoProfile -File (Join-Path $here $t)
    if ($LASTEXITCODE -ne 0) { $rc = 1 }
}
Write-Host "`n########## overall: $(if ($rc) {'FAIL'} else {'PASS'}) ##########"
exit $rc
