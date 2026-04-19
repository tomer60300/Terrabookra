<#
.SYNOPSIS
    Fleet command runner -- execute a command across all runners via PSRemoting.

.DESCRIPTION
    Run this from your ADMIN PC (not on the runners).
    Executes a script block on multiple runners in parallel and collects output.

    Prerequisites:
      - WinRM enabled on all runners (Enable-RemotePowerShell.ps1)
      - Your admin PC can reach runners on TCP 5985

    Usage examples:

      # Restart Docker on all runners
      .\Invoke-FleetCommand.ps1 -Runners runner01,runner02 -Command 'Restart-Service docker -Force'

      # Flush DNS on all runners
      .\Invoke-FleetCommand.ps1 -Runners runner01,runner02 -Command 'Clear-DnsClientCache'

      # Check disk space
      .\Invoke-FleetCommand.ps1 -Runners runner01,runner02 -Command '[math]::Round((Get-PSDrive C).Free/1GB,1)'

      # Collect log bundles from all runners
      .\Invoke-FleetCommand.ps1 -Runners runner01,runner02 -Command 'C:\GitLab-Runner\scripts\Export-RunnerLogs.ps1'

      # Kill stale Docker containers
      .\Invoke-FleetCommand.ps1 -Runners runner01,runner02 -Command 'docker container prune --force'

      # Check golden version
      .\Invoke-FleetCommand.ps1 -Runners runner01,runner02 -Command 'Get-Content C:\GitLab-Runner\.golden-version'

      # Run from a file of hostnames
      .\Invoke-FleetCommand.ps1 -Runners (Get-Content .\runners.txt) -Command 'hostname'

      # Run a multi-line script block
      .\Invoke-FleetCommand.ps1 -Runners runner01 -ScriptFile .\my-script.ps1

.PARAMETER Runners
    Array of runner hostnames or IPs.

.PARAMETER Command
    PowerShell command string to execute on each runner.

.PARAMETER ScriptFile
    Path to a .ps1 file to execute on each runner (alternative to -Command).

.PARAMETER Credential
    PSCredential for authentication. If omitted, uses current user.

.PARAMETER ThrottleLimit
    Max concurrent connections. Default: 10.

.NOTES
    File: fleet/Invoke-FleetCommand.ps1
    Runs on: Admin PC (NOT on runners)
#>

param(
    [Parameter(Mandatory)]
    [string[]]$Runners,

    [Parameter(ParameterSetName='Command')]
    [string]$Command,

    [Parameter(ParameterSetName='ScriptFile')]
    [string]$ScriptFile,

    [PSCredential]$Credential,

    [int]$ThrottleLimit = 10
)

$ErrorActionPreference = 'Continue'

# -- Validate input -------------------------------------------
if (-not $Command -and -not $ScriptFile) {
    Write-Error 'Provide either -Command or -ScriptFile'
    return
}

if ($ScriptFile) {
    if (-not (Test-Path $ScriptFile)) {
        Write-Error "Script file not found: $ScriptFile"
        return
    }
    $scriptContent = Get-Content $ScriptFile -Raw
    $scriptBlock   = [ScriptBlock]::Create($scriptContent)
} else {
    $scriptBlock = [ScriptBlock]::Create($Command)
}

# -- Display intent -------------------------------------------
$cmdDisplay = if ($ScriptFile) { "ScriptFile: $ScriptFile" } else { $Command }
Write-Output "`n  Targets: $($Runners -join ', ')"
Write-Output "  Command: $cmdDisplay"
Write-Output "  Throttle: $ThrottleLimit"
Write-Output ''

# -- Execute --------------------------------------------------
$invokeParams = @{
    ComputerName  = $Runners
    ScriptBlock   = $scriptBlock
    ErrorAction   = 'SilentlyContinue'
    ErrorVariable = 'remoteErrors'
    ThrottleLimit = $ThrottleLimit
}
if ($Credential) { $invokeParams.Credential = $Credential }

$results = Invoke-Command @invokeParams

# -- Display results grouped by host --------------------------
if ($results) {
    $grouped = $results | Group-Object -Property PSComputerName
    foreach ($group in $grouped) {
        Write-Output "--- $($group.Name) ---"
        $group.Group | ForEach-Object {
            # Strip PSComputerName from output if it's a simple value
            if ($_ -is [PSCustomObject] -or $_ -is [hashtable]) {
                $_ | Format-Table -AutoSize | Out-String | Write-Output
            } else {
                Write-Output "  $_"
            }
        }
    }
}

# -- Report unreachable hosts ---------------------------------
$reached = @()
if ($results) {
    $reached = $results | Select-Object -ExpandProperty PSComputerName -Unique
}
$unreachable = $Runners | Where-Object { $_ -notin $reached }

if ($unreachable.Count -gt 0) {
    Write-Output "`n  UNREACHABLE: $($unreachable -join ', ')"
}

Write-Output "`n  Done: $($reached.Count)/$($Runners.Count) runners responded."
