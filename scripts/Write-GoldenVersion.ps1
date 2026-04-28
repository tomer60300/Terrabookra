<#
.SYNOPSIS
    Write a golden image version stamp to a JSON file.

.DESCRIPTION
    Called at the end of Phase 3 (after validation passes).
    Creates a JSON file with the image build metadata so you can query
    any runner to know exactly what version it's running.

    Query from admin PC over SSH (WinRM is blocked by GPO -- use OpenSSH):
      foreach ($h in 'runner01','runner02','runner03') {
          ssh $h 'powershell -NoProfile -Command "Get-Content C:\GitLab-Runner\.golden-version"'
      }

.PARAMETER ImageVersion
    Golden image version string. Default: 2.4.0

.PARAMETER OutputPath
    Path to write the version stamp JSON. Default: C:\GitLab-Runner\.golden-version

.PARAMETER RunnerBin
    Path to gitlab-runner.exe. Default: C:\GitLab-Runner\gitlab-runner.exe

.PARAMETER GitExe
    Path to git.exe. Default: C:\GitLab-Runner\git\cmd\git.exe

.PARAMETER CertsDir
    Path to certificates directory. Default: C:\GitLab-Runner\certs

.NOTES
    File: scripts/Write-GoldenVersion.ps1
    Output: <OutputPath> (JSON)
#>

param(
    [string]$ImageVersion = '2.4.0',
    [string]$OutputPath   = 'C:\GitLab-Runner\.golden-version',
    [string]$RunnerBin    = 'C:\GitLab-Runner\gitlab-runner.exe',
    [string]$GitExe       = 'C:\GitLab-Runner\git\cmd\git.exe',
    [string]$CertsDir     = 'C:\GitLab-Runner\certs'
)

$ErrorActionPreference = 'Continue'

# -- Gather component versions --------------------------------
$runnerVersion = 'unknown'
try {
    $out = & $RunnerBin --version 2>&1 | Out-String
    if ($out -match 'Version:\s+([\d.]+)') { $runnerVersion = $Matches[1] }
} catch {}

$dockerVersion = 'unknown'
try {
    $dockerVersion = docker version --format '{{.Server.Version}}' 2>$null
    if (-not $dockerVersion) { $dockerVersion = 'unknown' }
} catch {}

$gitVersion = 'unknown'
if (Test-Path $GitExe) {
    try {
        $gitVersion = & $GitExe --version 2>$null
        $gitVersion = $gitVersion -replace 'git version\s*', ''
    } catch {}
}

$osBuild = [System.Environment]::OSVersion.Version.Build

# -- Build stamp ----------------------------------------------
$stamp = [ordered]@{
    ImageVersion   = $ImageVersion
    BuildDate      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    BuildHost      = $env:COMPUTERNAME
    OSBuild        = $osBuild
    RunnerVersion  = $runnerVersion
    DockerVersion  = $dockerVersion
    GitVersion     = $gitVersion
    ScriptVersion  = $ImageVersion
    Components     = [ordered]@{
        Certificates       = (Test-Path (Join-Path $CertsDir '*.crt'))
        Sshd               = ((Get-Service sshd -EA SilentlyContinue).Status -eq 'Running')
        WindowsExporter    = ((Get-Service windows_exporter  -EA SilentlyContinue).Status -eq 'Running')
        BlackboxExporter   = ((Get-Service blackbox_exporter -EA SilentlyContinue).Status -eq 'Running')
        WebView2           = ([bool](
            @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
              'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}') |
                Where-Object { Test-Path $_ } | Select-Object -First 1 |
                ForEach-Object { (Get-ItemProperty -Path $_ -Name pv -EA SilentlyContinue).pv }
        ))
        OpenCodeConfig     = (Test-Path 'C:\ProgramData\opencode\opencode.jsonc')
        ScheduledTasks     = (Get-ScheduledTask -EA SilentlyContinue |
                              Where-Object { $_.TaskName -match '^(Docker|Runner|Disk|Log|Network|RDP)-' } |
                              Measure-Object).Count
    }
    Tools          = [ordered]@{
        WinRAR          = (Test-Path 'C:\Program Files\WinRAR\WinRAR.exe')
        NSSM            = (Test-Path 'C:\Tools\nssm.exe')
        Sysinternals    = (Test-Path 'C:\Tools\SysInternals\procexp64.exe')
        NotepadPP       = (Test-Path 'C:\Program Files\Notepad++\notepad++.exe')
        WinMerge        = (Test-Path 'C:\Program Files\WinMerge\WinMergeU.exe')
        BareTail        = (Test-Path 'C:\Program Files\BareTail\baretail.exe')
        Klogg           = (Test-Path 'C:\Program Files\klogg\klogg.exe')
        Everything      = (Test-Path 'C:\Program Files\Everything\Everything.exe')
        WizTree         = (Test-Path 'C:\Program Files\WizTree\WizTree.exe')
        SystemInformer  = (Test-Path 'C:\Program Files\SystemInformer\SystemInformer.exe')
        EventLook       = (Test-Path 'C:\Program Files\EventLook\EventLook.exe')
        Tshark          = (Test-Path 'C:\Program Files\Wireshark\tshark.exe')
        Chrome          = (Test-Path 'C:\Program Files\Google\Chrome\Application\chrome.exe')
        WindowsTerminal = (Test-Path 'C:\Program Files\WindowsTerminal\wt.exe')
    }
    MetricsEndpoints = [ordered]@{
        WindowsExporter  = "http://${env:COMPUTERNAME}:9182/metrics"
        BlackboxExporter = "http://${env:COMPUTERNAME}:9115/probe"
        GitLabRunner     = "http://${env:COMPUTERNAME}:9252/metrics"
        Docker           = "http://${env:COMPUTERNAME}:9323/metrics"
    }
}

ConvertTo-Json -InputObject $stamp -Depth 3 | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
Write-Output "Golden image version stamp written: $OutputPath"
Write-Output "  Image: $ImageVersion | Runner: $runnerVersion | Docker: $dockerVersion | Build: $osBuild"
