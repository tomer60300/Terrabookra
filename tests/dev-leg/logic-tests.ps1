#!/usr/bin/env pwsh
# Mock-execute the migration's PowerShell logic on Linux pwsh 7.
# Windows-only cmdlets are stubbed; native exes are shimmed. Caveats: pwsh 7 != PS
# 5.1, and Windows cmdlet BEHAVIOR is mocked (we verify our logic + call shapes).
$ErrorActionPreference = 'Stop'
$REPO = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path

$script:tpass = 0; $script:tfail = 0; $script:tfailed = @()
function it($name, $block) {
    try { & $block; Write-Host "  [PASS] $name"; $script:tpass++ }
    catch { Write-Host "  [FAIL] $name -- $($_.Exception.Message)"; $script:tfail++; $script:tfailed += $name }
}
function eqs($actual, $expected, $msg) { if ("$actual" -ne "$expected") { throw "$msg (expected '$expected' got '$actual')" } }
function ok($cond, $msg) { if (-not $cond) { throw $msg } }
function notok($cond, $msg) { if ($cond) { throw $msg } }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# ============================================================
Write-Host "`n== Config.ps1 : env-driven alias resolution =="
it 'default alias when REAL_* unset' {
    Remove-Item Env:REAL_GITLAB_HOST -EA SilentlyContinue
    . $REPO/lib/Config.ps1
    eqs $Script:Config.GitLabUrl 'https://gitlab.kayhut.com' 'GitLabUrl default'
    eqs $Script:Config.GitLabRegistry 'gitlab.kayhut.com:5050' 'registry default'
}
it 'REAL_* override wins' {
    $env:REAL_GITLAB_HOST = 'gitlab.internal.corp'
    $env:REAL_GITLAB_REGISTRY = 'reg.internal.corp:5050'
    . $REPO/lib/Config.ps1
    eqs $Script:Config.GitLabUrl 'https://gitlab.internal.corp' 'GitLabUrl override'
    eqs $Script:Config.GitLabRegistry 'reg.internal.corp:5050' 'registry override'
    Remove-Item Env:REAL_GITLAB_HOST, Env:REAL_GITLAB_REGISTRY -EA SilentlyContinue
}
it 'Harbor fully retired (no Harbor keys)' {
    . $REPO/lib/Config.ps1
    notok ($Script:Config.ContainsKey('HarborUrl')) 'HarborUrl should be gone'
    notok ($Script:Config.ContainsKey('HarborProject')) 'HarborProject should be gone'
    ok ($Script:Config.PrePullImages[0] -like '*gitlab.kayhut.com:5050/*') 'pre-pull images point at GitLab registry'
}
it 'MinIO connection keys + Be1 removed' {
    . $REPO/lib/Config.ps1
    notok ($Script:Config.ContainsKey('MinioEndpoint')) 'MinioEndpoint should be gone'
    notok ($Script:Config.ContainsKey('Be1Host')) 'Be1Host should be gone'
    notok ($Script:Config.MonitorHosts.Host -contains 'be1.kayhut.com') 'be1 not monitored'
}
it 'registry creds env-injected' {
    $env:REAL_GITLAB_REGISTRY_USER = 'deploy-token'; $env:REAL_GITLAB_REGISTRY_PASS = 'sekret'
    . $REPO/lib/Config.ps1
    eqs $Script:Config.GitLabRegistryUser 'deploy-token' 'registry user from env'
    eqs $Script:Config.GitLabRegistryPass 'sekret' 'registry pass from env'
    Remove-Item Env:REAL_GITLAB_REGISTRY_USER, Env:REAL_GITLAB_REGISTRY_PASS -EA SilentlyContinue
}

# ============================================================
Write-Host "`n== Common.ps1 : local artifact helpers (real temp tree) =="
. $REPO/lib/Config.ps1
. $REPO/lib/Common.ps1
$repoSave = $Script:RepoRoot
$Script:RepoRoot = $tmp                      # point helpers at a controlled tree
$Script:LogFile = Join-Path $tmp 'install.log'  # Write-Log's C:\ default is invalid on Linux
New-Item -ItemType Directory -Path (Join-Path $tmp 'binaries/git') -Force | Out-Null
# a real PE (MZ) binary and a real zip
[System.IO.File]::WriteAllBytes((Join-Path $tmp 'binaries/real.exe'), ([byte[]]@(0x4D,0x5A) + (1..40)))
[System.IO.File]::WriteAllBytes((Join-Path $tmp 'binaries/pointer.exe'), [Text.Encoding]::ASCII.GetBytes("version https://git-lfs.github.com/spec/v1`noid sha256:abc`nsize 123`n"))
$zipSrc = Join-Path $tmp 'src.zip'
Compress-Archive -Path (Join-Path $tmp 'binaries/real.exe') -DestinationPath $zipSrc -Force
Copy-Item $zipSrc (Join-Path $tmp 'binaries/git/MinGit.zip')

it 'Get-RepoPath joins + normalizes slashes' {
    eqs (Get-RepoPath 'binaries/real.exe') (Join-Path $tmp 'binaries/real.exe') 'repo path'
}
it 'Test-PEBinary true on MZ, false on pointer' {
    ok (Test-PEBinary (Join-Path $tmp 'binaries/real.exe')) 'MZ is PE'
    notok (Test-PEBinary (Join-Path $tmp 'binaries/pointer.exe')) 'pointer is not PE'
}
it 'Copy-RepoFile copies + returns true; false on missing' {
    $out = Join-Path $tmp 'out/copied.exe'
    ok (Copy-RepoFile -RelPath 'binaries/real.exe' -OutFile $out) 'copy ok'
    ok (Test-Path $out) 'file present'
    notok (Copy-RepoFile -RelPath 'binaries/nope.exe' -OutFile (Join-Path $tmp 'out/x')) 'missing returns false'
}
it 'Install-LocalBinary validates PE; rejects pointer' {
    ok (Install-LocalBinary -RelPath 'binaries/real.exe' -DestPath (Join-Path $tmp 'd/r.exe') -Label 'r') 'real installs'
    notok (Install-LocalBinary -RelPath 'binaries/pointer.exe' -DestPath (Join-Path $tmp 'd/p.exe') -Label 'p') 'pointer rejected'
}
it 'Install-LocalArchive extracts zip' {
    ok (Install-LocalArchive -RelPath 'binaries/git/MinGit.zip' -DestDir (Join-Path $tmp 'mingit') -TestFile (Join-Path $tmp 'mingit/none') -Label 'MinGit') 'extract ok'
    ok ((Get-ChildItem (Join-Path $tmp 'mingit')).Count -gt 0) 'extracted files exist'
}
$Script:RepoRoot = $repoSave

# ============================================================
Write-Host "`n== Invoke-FinalValidation.ps1 : build-gate vs deploy-gate (mocked Windows) =="
# Stub the Windows-only surface BEFORE dot-sourcing the gate functions.
function Get-WindowsFeature { [CmdletBinding()] param() [pscustomobject]@{ Installed = $true } }
function Get-Service { [CmdletBinding()] param([Parameter(ValueFromPipeline, Position = 0)]$Name) [pscustomobject]@{ Status = $script:svcStatus } }
function Get-MpPreference { [CmdletBinding()] param() [pscustomobject]@{ ExclusionPath = @($Script:Config.RunnerDir) } }
function powercfg { '... GUID: 8c5e7fda-... (High performance) *' }
function Get-ScheduledTask { [CmdletBinding()] param($TaskName)
    if (-not $script:tasksPresent) { return }
    $set = [pscustomobject]@{ ExecutionTimeLimit = 'PT2H' }
    if ($TaskName) { return ([pscustomobject]@{ TaskName = $TaskName; Settings = $set }) }
    $script:allTasks | ForEach-Object { [pscustomobject]@{ TaskName = $_; Settings = $set } }
}
function Get-NetFirewallRule { [CmdletBinding()] param($Name) if ($script:fwPresent) { [pscustomobject]@{ Name = $Name } } }
function docker { if ($args -contains 'version') { '25.0.15' } elseif ($args -contains 'info') { 'process' } elseif ($args -contains 'images') { 'v16.7.0' } elseif ($args -contains 'verify') { 'Runtime platform ... is alive' } ; $global:LASTEXITCODE = 0 }
# stub gitlab-runner.exe for the `& $Config.RunnerBin verify` check
$runnerStub = Join-Path $tmp 'gitlab-runner'
Set-Content -Path $runnerStub -Value "#!/bin/bash`necho 'Runtime platform ... is alive'`nexit 0"
chmod +x $runnerStub
$Script:Config.RunnerBin = $runnerStub
$script:svcStatus = 'Running'; $script:tasksPresent = $true; $script:fwPresent = $true
$script:allTasks = @('Docker-Image-Prune','Docker-Container-Cleanup','Docker-Stale-Container-Kill','Docker-Volume-Prune','Docker-BuildCache-Prune','Runner-Workspace-Cleanup','Disk-Space-Monitor','Docker-Daemon-Watchdog','Runner-Service-Watchdog','Log-Rotation','Network-Connectivity-Monitor','RDP-Audit-Logger','Health-Check')
. $REPO/validation/Invoke-FinalValidation.ps1

it 'build-gate does NOT probe runner service / verify / scheduled tasks' {
    # capture the check names by intercepting Write-Log
    $script:logged = @()
    function Write-Log { param($Message,$Level='INFO') $script:logged += $Message }
    Invoke-FinalValidation
    $names = ($script:logged -join "`n")
    notok ($names -match 'Runner service running') 'build-gate must not check runner service'
    notok ($names -match 'Runner verify') 'build-gate must not run gitlab-runner verify'
    notok ($names -match 'Scheduled tasks \(13') 'build-gate must not check the 13 tasks'
    ok ($names -match 'OS Build = 17763') 'build-gate checks OS build'
    ok ($names -match 'Docker isolation = process') 'build-gate checks isolation'
    Remove-Item function:Write-Log -EA SilentlyContinue
}
it 'deploy-gate DOES check service + verify + tasks, returns bool' {
    $script:logged = @()
    function Write-Log { param($Message,$Level='INFO') $script:logged += $Message }
    $r = Test-RunnerRegistered
    $names = ($script:logged -join "`n")
    ok ($names -match 'Runner service running') 'deploy-gate checks service'
    ok ($names -match 'Runner verify') 'deploy-gate runs verify'
    ok ($names -match 'Scheduled tasks \(13') 'deploy-gate checks tasks'
    ok ($r -eq $true) 'all-pass returns $true'
    Remove-Item function:Write-Log -EA SilentlyContinue
}
it 'deploy-gate returns $false when service down' {
    $script:svcStatus = 'Stopped'
    function Write-Log { param($Message,$Level='INFO') }
    $r = Test-RunnerRegistered
    ok ($r -eq $false) 'service down => $false'
    $script:svcStatus = 'Running'
    Remove-Item function:Write-Log -EA SilentlyContinue
}

# ============================================================
Write-Host "`n== Summary =="
Write-Host "PASS=$script:tpass FAIL=$script:tfail"
if ($script:tfail) { $script:tfailed | ForEach-Object { Write-Host "  - $_" }; exit 1 }
Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
exit 0
