<#
.SYNOPSIS
    Write a golden image version stamp to a JSON file.

.DESCRIPTION
    Called at the end of Phase 3 (after validation passes).
    Creates a JSON file with the image build metadata so you can query
    any runner to know exactly what version it's running.

    Query from admin PC:
      Invoke-Command -ComputerName runner01,runner02,runner03 -ScriptBlock {
          Get-Content C:\GitLab-Runner\.golden-version | ConvertFrom-Json
      } | Format-Table PSComputerName, ImageVersion, BuildDate, RunnerVersion, DockerVersion

.PARAMETER ImageVersion
    Golden image version string. Default: 2.3.0

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
    [string]$ImageVersion = '2.3.0',
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
        Certificates    = (Test-Path (Join-Path $CertsDir '*.crt'))
        WinRM           = ((Get-Service WinRM -ErrorAction SilentlyContinue).Status -eq 'Running')
        ScheduledTasks  = (Get-ScheduledTask -ErrorAction SilentlyContinue |
                          Where-Object { $_.TaskName -match '^(Docker|Runner|Disk|Log|Network|RDP)-' } |
                          Measure-Object).Count
    }
}

ConvertTo-Json -InputObject $stamp -Depth 3 | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
Write-Output "Golden image version stamp written: $OutputPath"
Write-Output "  Image: $ImageVersion | Runner: $runnerVersion | Docker: $dockerVersion | Build: $osBuild"
