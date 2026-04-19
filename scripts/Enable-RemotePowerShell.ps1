<#
.SYNOPSIS
    Enable WinRM PSRemoting on this VM for remote PowerShell access.

.DESCRIPTION
    Configures WinRM for remote management:
    1. Enable PSRemoting
    2. Set WinRM service to auto-start
    3. Configure TrustedHosts (optional -- for non-domain or cross-domain)
    4. Open firewall for WinRM (TCP 5985/5986)
    5. Set MaxMemoryPerShellMB for heavy operations

    Run this on the RUNNER VM. Then connect from your PC with:
      Enter-PSSession -ComputerName <runner-hostname> -Credential (Get-Credential)

.PARAMETER TrustedHosts
    Comma-separated list of hosts allowed to connect. Default: '*' (any).
    For production, restrict to your admin PC IP or hostname.

.NOTES
    File: scripts/Enable-RemotePowerShell.ps1
    Run as: Administrator
    Called during: Phase 1 (step 1.11)
#>

param(
    [string]$TrustedHosts = '*'
)

$ErrorActionPreference = 'Continue'

# -- 1. Enable PSRemoting -------------------------------------
Write-Output '1. Enable PSRemoting...'
Enable-PSRemoting -Force -SkipNetworkProfileCheck 2>&1 | ForEach-Object { Write-Output "  $_" }

# -- 2. WinRM service auto-start ------------------------------
Write-Output '2. Set WinRM service to auto-start...'
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM -ErrorAction SilentlyContinue

# -- 3. TrustedHosts ------------------------------------------
Write-Output "3. Set TrustedHosts: $TrustedHosts"
Set-Item WSMan:\localhost\Client\TrustedHosts -Value $TrustedHosts -Force

# -- 4. WinRM config tuning -----------------------------------
Write-Output '4. Configure WinRM limits...'
Set-Item WSMan:\localhost\Shell\MaxMemoryPerShellMB -Value 2048 -Force
Set-Item WSMan:\localhost\Shell\MaxShellsPerUser -Value 30 -Force
Set-Item WSMan:\localhost\Plugin\microsoft.powershell\Quotas\MaxMemoryPerShellMB -Value 2048 -Force

# -- 5. Firewall rules ----------------------------------------
Write-Output '5. Configure firewall rules...'
$rules = @(
    @{ Name = 'WinRM-HTTP';  Port = 5985; Description = 'WinRM HTTP' },
    @{ Name = 'WinRM-HTTPS'; Port = 5986; Description = 'WinRM HTTPS' }
)
foreach ($r in $rules) {
    $existing = Get-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Output "  Firewall rule '$($r.Name)' already exists"
    } else {
        New-NetFirewallRule -Name $r.Name -DisplayName $r.Description `
            -Direction Inbound -Protocol TCP -LocalPort $r.Port -Action Allow | Out-Null
        Write-Output "  Created firewall rule: $($r.Name) (TCP $($r.Port))"
    }
}

# -- 6. Restart WinRM -----------------------------------------
Write-Output '6. Restart WinRM...'
Restart-Service WinRM

# -- Verify ---------------------------------------------------
$status = (Get-Service WinRM).Status
$listener = Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue
Write-Output "`nWinRM Status: $status"
Write-Output "Listeners: $($listener.Count)"
Write-Output "`nRemote PowerShell is ready. Connect from your PC with:"
Write-Output "  Enter-PSSession -ComputerName $env:COMPUTERNAME -Credential (Get-Credential)"
