<#
.SYNOPSIS
    Final validation -- 17-check suite to confirm the runner is fully operational.

.DESCRIPTION
    Called at the end of Phase 3. Runs checks against OS, Docker, Runner, Git,
    Defender, scheduled tasks, and disk. Results are written to the install log
    and to the Application Event Log.

    Exit criteria:
      - All 17 checks PASS -> Event 9011 (Info)
      - Any check FAIL     -> Event 9010 (Warning) -- runner may still work

.NOTES
    File: validation/Invoke-FinalValidation.ps1
    Requires: lib/Config.ps1, lib/Common.ps1 (dot-sourced by orchestrator)

    Checks:
      1   OS Build = 17763
      2   Containers feature installed
      3   Hyper-V feature installed
      4   Docker service running
      5   Docker version = 25.0.x
      6   Docker isolation = process
      7   Runner binary valid (PE header)
      8   Runner service running
      9   Runner verify (is alive)
      10  Git available
      11  GIT_SSL_NO_VERIFY set
      12  Defender exclusions applied
      13  Helper image present
      14  Scheduled tasks >= 8
      15  Power plan = High Performance
      16  Long paths enabled
      17  Disk free >= 50 GB
#>

function Invoke-FinalValidation {
    $pass = 0; $fail = 0; $total = 0

    function Check {
        param([string]$Name, [scriptblock]$Test)
        $script:total++
        try {
            if (& $Test) { Write-Log "  [PASS] $Name"; $script:pass++ }
            else          { Write-Log "  [FAIL] $Name" -Level 'WARN'; $script:fail++ }
        }
        catch { Write-Log "  [FAIL] $Name -- $_" -Level 'WARN'; $script:fail++ }
    }

    Check 'OS Build = 17763'            { [System.Environment]::OSVersion.Version.Build -eq 17763 }
    Check 'Containers feature'          { (Get-WindowsFeature Containers).Installed }
    Check 'Hyper-V feature'             { (Get-WindowsFeature Hyper-V).Installed }
    Check 'Docker service running'      { (Get-Service docker -ErrorAction SilentlyContinue).Status -eq 'Running' }
    Check 'Docker version = 25.0'       { (docker version --format '{{.Server.Version}}' 2>$null) -match '25\.0' }
    Check 'Docker isolation = process'  { (docker info --format '{{.Isolation}}' 2>$null) -eq 'process' }
    Check 'Runner binary valid'         { Test-PEBinary $Script:Config.RunnerBin }
    Check 'Runner service running'      { (Get-Service gitlab-runner -ErrorAction SilentlyContinue).Status -eq 'Running' }
    Check 'Runner verify (is alive)'    { (& $Script:Config.RunnerBin verify 2>&1 | Out-String) -match 'is alive' }
    Check 'Git available'               { Test-Path (Join-Path $Script:Config.GitDir 'cmd\git.exe') }
    Check 'GIT_SSL_NO_VERIFY set'       { [System.Environment]::GetEnvironmentVariable('GIT_SSL_NO_VERIFY','Machine') -eq 'true' }
    Check 'Defender exclusions'         { (Get-MpPreference).ExclusionPath -contains $Script:Config.RunnerDir }
    Check 'Helper image present'        { (docker images $Script:Config.HelperImage --format '{{.Tag}}' 2>$null) -match 'v16.7.0' }
    Check 'Scheduled tasks (>=10)'      { (Get-ScheduledTask | Where-Object { $_.TaskName -match '^(Docker|Runner|Disk|Log|Network|RDP)-' } | Measure-Object).Count -ge 10 }
    Check 'Power plan = High Perf'      { (powercfg /getactivescheme) -match '8c5e7fda' }
    Check 'Long paths enabled'          { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem').LongPathsEnabled -eq 1 }
    Check 'Disk free C: >= 50 GB'       { [math]::Round((Get-PSDrive C).Free / 1GB) -ge 50 }
    # Check data drive if separate from C:
    $dd = if (Test-Path 'E:\') { 'E' } else { $null }
    if ($dd) {
    Check "Disk free ${dd}: >= 50 GB"    { [math]::Round((Get-PSDrive $dd).Free / 1GB) -ge 50 }
    }

    Write-Log "Validation: $pass/$total passed, $fail failed"

    if ($fail -gt 0) {
        Write-EventLog -LogName Application -Source 'GitLabRunner' -EventId 9010 -EntryType Warning `
            -Message "Validation: $fail of $total checks failed."
    } else {
        Write-EventLog -LogName Application -Source 'GitLabRunner' -EventId 9011 -EntryType Information `
            -Message "Validation: ALL $total checks passed."
    }
}
