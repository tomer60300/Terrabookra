<#
.SYNOPSIS
    Register all maintenance scheduled tasks for the GitLab Runner golden image.

.DESCRIPTION
    Run once during Phase 3 of Bootstrap-GitLabRunner.ps1.
    Creates 12 scheduled tasks under SYSTEM for Docker cleanup, disk monitoring,
    service watchdogs, log rotation, network monitoring, and RDP audit.

.PARAMETER ScriptsDir
    Path to the scripts directory. Default: C:\GitLab-Runner\scripts

.PARAMETER LogsDir
    Path to the logs directory. Default: C:\GitLab-Runner\logs

.PARAMETER BuildsDir
    Path to the builds directory. Default: C:\GitLab-Runner\builds

.NOTES
    All tasks run as SYSTEM with highest privileges.
    Repeating tasks use -RepetitionDuration of 3650 days (10 years).

    Task schedule:
      Docker-Image-Prune          Daily  03:00
      Docker-Container-Cleanup    Every  4 hours
      Docker-Stale-Container-Kill Every  2 hours
      Docker-Volume-Prune         Daily  03:30
      Docker-BuildCache-Prune     Weekly Sunday 04:00
      Runner-Workspace-Cleanup    Daily  04:00
      Disk-Space-Monitor          Every  30 minutes
      Docker-Daemon-Watchdog      Every  5 minutes
      Runner-Service-Watchdog     Every  5 minutes
      Log-Rotation                Weekly Sunday 05:00
      Network-Connectivity-Monitor Every  2 minutes
      RDP-Audit-Logger            Every  5 minutes
#>

param(
    [string]$ScriptsDir = 'C:\GitLab-Runner\scripts',
    [string]$LogsDir    = 'C:\GitLab-Runner\logs',
    [string]$BuildsDir  = 'C:\GitLab-Runner\builds'
)

$ErrorActionPreference = 'Stop'

$principal  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$forever    = New-TimeSpan -Days 3650

$tasks = @(
    @{
        Name    = 'Docker-Image-Prune'
        Trigger = New-ScheduledTaskTrigger -Daily -At '03:00'
        Args    = "-NoProfile -Command `"docker image prune -a --filter 'until=168h' --force 2>&1 | Out-File '$LogsDir\image-prune.log' -Append`""
    },
    @{
        Name    = 'Docker-Container-Cleanup'
        Trigger = New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Hours 4) -RepetitionDuration $forever
        Args    = "-NoProfile -Command `"docker container prune --force 2>&1 | Out-File '$LogsDir\container-prune.log' -Append`""
    },
    @{
        Name    = 'Docker-Stale-Container-Kill'
        Trigger = New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Hours 2) -RepetitionDuration $forever
        Args    = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptsDir\kill-stale-containers.ps1`""
    },
    @{
        Name    = 'Docker-Volume-Prune'
        Trigger = New-ScheduledTaskTrigger -Daily -At '03:30'
        Args    = "-NoProfile -Command `"docker volume prune --force 2>&1 | Out-File '$LogsDir\volume-prune.log' -Append`""
    },
    @{
        Name    = 'Docker-BuildCache-Prune'
        Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '04:00'
        Args    = "-NoProfile -Command `"docker builder prune --all --force 2>&1 | Out-File '$LogsDir\buildcache-prune.log' -Append`""
    },
    @{
        Name    = 'Runner-Workspace-Cleanup'
        Trigger = New-ScheduledTaskTrigger -Daily -At '04:00'
        Args    = "-NoProfile -Command `"Get-ChildItem '$BuildsDir' -Directory | Where-Object { `$_.LastWriteTime -lt (Get-Date).AddDays(-3) } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue`""
    },
    @{
        Name    = 'Disk-Space-Monitor'
        Trigger = New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration $forever
        Args    = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptsDir\disk-monitor.ps1`""
    },
    @{
        Name    = 'Docker-Daemon-Watchdog'
        Trigger = New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration $forever
        Args    = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptsDir\docker-watchdog.ps1`""
    },
    @{
        Name    = 'Runner-Service-Watchdog'
        Trigger = New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration $forever
        Args    = "-NoProfile -Command `"if ((Get-Service gitlab-runner -ErrorAction SilentlyContinue).Status -ne 'Running') { Start-Service gitlab-runner; Write-EventLog -LogName Application -Source 'GitLabRunner' -EventId 9004 -EntryType Warning -Message 'Runner service was not running. Restarted.' }`""
    },
    @{
        Name    = 'Log-Rotation'
        Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '05:00'
        Args    = "-NoProfile -Command `"Get-ChildItem '$LogsDir\*.log' | Where-Object { `$_.Length -gt 50MB } | ForEach-Object { Move-Item `$_.FullName (`$_.FullName + '.old') -Force }`""
    },
    # -- New feature tasks ------------------------------------
    @{
        Name    = 'Network-Connectivity-Monitor'
        Trigger = New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration $forever
        Args    = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptsDir\Test-NetworkConnectivity.ps1`""
    },
    @{
        Name    = 'RDP-Audit-Logger'
        Trigger = New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration $forever
        Args    = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptsDir\Export-RdpAuditLog.ps1`""
    }
)

$registered = 0
foreach ($t in $tasks) {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $t.Args
    Register-ScheduledTask -TaskName $t.Name -Action $action -Trigger $t.Trigger -Principal $principal -Force | Out-Null
    $registered++
    Write-Output "  Registered: $($t.Name)"
}

Write-Output "All $registered scheduled tasks registered."
