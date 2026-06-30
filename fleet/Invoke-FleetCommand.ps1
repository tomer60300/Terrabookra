<#
.SYNOPSIS
    Fleet command runner -- execute a command across all runners via OpenSSH.

.DESCRIPTION
    Run this from your ADMIN PC (not on the runners). Executes a PowerShell
    command on multiple runners in parallel via OpenSSH and collects output.

    Replaces the prior PSRemoting/WinRM transport, which is blocked at Kayhut
    by domain GPO. OpenSSH is enabled on every runner by Phase 1 step 1.11.

    Auth (in order of preference):
      1. SSH key auth -- pass -PrivateKey to use a specific identity file.
         Public key must be in C:\ProgramData\ssh\administrators_authorized_keys
         on each runner (if the user is in BUILTIN\Administrators) or
         %USERPROFILE%\.ssh\authorized_keys (for non-admin accounts).
      2. AD password auth -- if no key matches, ssh prompts per host. Domain
         users on a domain-joined runner are validated by Windows logon
         against the DC. Slow for fan-out (one prompt per host).
      3. GSSAPI/Kerberos -- if your admin PC is domain-joined and you have a
         current TGT, pass -KerberosAuth to skip both passwords and keys.
         Requires the runner sshd_config to set GSSAPIAuthentication yes.

.PARAMETER Runners
    Array of runner hostnames or IPs.

.PARAMETER Command
    PowerShell command string to execute on each runner.

.PARAMETER ScriptFile
    Path to a .ps1 file to execute on each runner (alternative to -Command).

.PARAMETER SshUser
    Username for SSH login. Defaults to current user. For AD users, use
    'DOMAIN\username' or 'username@domain.tld'.

.PARAMETER PrivateKey
    Path to an SSH private key (e.g. ~/.ssh/id_ed25519). Skips password prompt.

.PARAMETER KerberosAuth
    Use GSSAPI/Kerberos auth (passwordless on a domain-joined admin PC with a
    current TGT). Requires runner sshd_config: GSSAPIAuthentication yes.

.PARAMETER ThrottleLimit
    Max concurrent SSH connections. Default: 10.

.NOTES
    File: fleet/Invoke-FleetCommand.ps1
    Runs on: Admin PC (NOT on runners). Requires ssh.exe on PATH (Windows 10+
    has OpenSSH client by default; otherwise install OpenSSH client optional
    feature or use Git for Windows' bundled ssh).
#>

param(
    [Parameter(Mandatory)]
    [string[]]$Runners,

    [Parameter(ParameterSetName='Command')]
    [string]$Command,

    [Parameter(ParameterSetName='ScriptFile')]
    [string]$ScriptFile,

    [string]$SshUser,
    [string]$PrivateKey,
    [switch]$KerberosAuth,

    [int]$ThrottleLimit = 10
)

$ErrorActionPreference = 'Continue'

if (-not $Command -and -not $ScriptFile) {
    Write-Error 'Provide either -Command or -ScriptFile'
    return
}
if ($ScriptFile) {
    if (-not (Test-Path $ScriptFile)) { Write-Error "Script file not found: $ScriptFile"; return }
    $payload = Get-Content $ScriptFile -Raw
} else {
    $payload = $Command
}

# Password auth cannot work inside Start-Job: the background job has no TTY, so
# ssh's interactive password prompt can never be answered and every host fails
# silently (the tool would just report "0/N returned exit 0"). Require key or
# Kerberos and fail fast and loud instead.
if (-not $PrivateKey -and -not $KerberosAuth) {
    Write-Error 'No -PrivateKey or -KerberosAuth supplied. Password auth cannot work inside a background job (no TTY). Pass -PrivateKey <identity-file> or -KerberosAuth.'
    return
}

# UTF-16LE base64 -- powershell.exe -EncodedCommand expects exactly this.
$bytes = [System.Text.Encoding]::Unicode.GetBytes($payload)
$b64   = [Convert]::ToBase64String($bytes)

$baseArgs = @(
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', 'UserKnownHostsFile=~/.ssh/fleet_known_hosts',
    '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=10'
)
if ($PrivateKey)   { $baseArgs += @('-i', $PrivateKey) }
if ($KerberosAuth) { $baseArgs += @('-o', 'GSSAPIAuthentication=yes', '-o', 'GSSAPIDelegateCredentials=yes') }

$cmdDisplay = if ($ScriptFile) { "ScriptFile: $ScriptFile" } else { $Command }
Write-Output ''
Write-Output "  Targets : $($Runners -join ', ')"
Write-Output "  Command : $cmdDisplay"
Write-Output "  Throttle: $ThrottleLimit"
if ($PrivateKey)        { Write-Output "  Auth    : SSH key ($PrivateKey)" }
elseif ($KerberosAuth)  { Write-Output '  Auth    : Kerberos (GSSAPI)' }
else                    { Write-Output '  Auth    : password (will prompt per host)' }
Write-Output ''

$jobs = @()
foreach ($runner in $Runners) {
    $target = if ($SshUser) { "$SshUser@$runner" } else { $runner }
    $jobs += Start-Job -Name $runner -ArgumentList $target,$baseArgs,$b64 -ScriptBlock {
        param($Target, $BaseArgs, $EncodedPayload)
        $sshArgs = $BaseArgs + @($Target, 'powershell.exe', '-NoProfile', '-EncodedCommand', $EncodedPayload)
        $stdout = & ssh @sshArgs 2>&1
        $exitCode = $LASTEXITCODE
        [PSCustomObject]@{
            Output   = ($stdout -join "`n")
            ExitCode = $exitCode
        }
    }
    while (@(Get-Job -State Running).Count -ge $ThrottleLimit) { Start-Sleep -Milliseconds 200 }
}

$reached = 0
foreach ($job in $jobs) {
    Wait-Job -Job $job | Out-Null
    $r = Receive-Job -Job $job
    Remove-Job -Job $job

    Write-Output "--- $($job.Name) (exit $($r.ExitCode)) ---"
    Write-Output $r.Output
    Write-Output ''
    if ($r.ExitCode -eq 0) { $reached++ }
}

Write-Output "  Done: $reached/$($Runners.Count) runners returned exit 0."
