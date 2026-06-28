#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Thin Packer entry point: dot-source Config + Common + the requested phase file
    and run that phase, then exit 0. Packer owns the `windows-restart` BETWEEN
    phases -- the phases no longer self-reboot or self-chain.

.DESCRIPTION
    Replaces the Be1 marker-dispatch in Bootstrap-GitLabRunner.ps1. Packer's
    golden build calls this once per phase:
        Invoke-Phase.ps1 -Phase 1   -> Invoke-Phase1        (system prep)
        <windows-restart>
        Invoke-Phase.ps1 -Phase 2   -> Invoke-Phase2        (docker install)
        <windows-restart>
        Invoke-Phase.ps1 -Phase 3   -> Invoke-Phase3Install (runner image + build-gate)

    Existence-only phase markers still guard against accidental re-runs, but they
    are no longer the driver -- Packer drives the order. A phase that hits a fatal
    condition calls `exit 1`, which fails the Packer build.

.PARAMETER Phase
    1, 2, or 3.

.PARAMETER RepoRoot
    The uploaded repo root. Default: parent of this provisioners/ directory.

.NOTES
    File: provisioners/Invoke-Phase.ps1
    PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('1','2','3')][string]$Phase,
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'

$libDir = Join-Path $RepoRoot 'lib'
. (Join-Path $libDir 'Config.ps1')
. (Join-Path $libDir 'Common.ps1')

Write-Log "============================================"
Write-Log "Invoke-Phase -Phase $Phase  (RepoRoot=$RepoRoot)"
Write-Log "Host: $env:COMPUTERNAME | OS: $([System.Environment]::OSVersion.VersionString) | DataDrive: $Script:DataDrive"
Write-Log "============================================"

switch ($Phase) {
    '1' {
        . (Join-Path $RepoRoot 'phases\Phase1-SystemPrep.ps1')
        Invoke-Phase1
    }
    '2' {
        . (Join-Path $RepoRoot 'phases\Phase2-DockerInstall.ps1')
        Invoke-Phase2
    }
    '3' {
        . (Join-Path $RepoRoot 'phases\Phase3-Install.ps1')
        . (Join-Path $RepoRoot 'validation\Invoke-FinalValidation.ps1')
        Invoke-Phase3Install
    }
}

Write-Log "Invoke-Phase -Phase $Phase finished."
exit 0
