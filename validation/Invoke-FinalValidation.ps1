<#
.SYNOPSIS
    Validation, split into two gates:
      Invoke-FinalValidation  -- BUILD-gate: image-correctness only. Passes on a
                                 GENERIC, UNREGISTERED golden image. Run at the end
                                 of Phase3-Install (Packer build).
      Test-RunnerRegistered   -- DEPLOY-gate: confirms a registered, running runner
                                 + its dependent services/tasks. Run at first boot
                                 (Register-RunnerFirstBoot.ps1) / acceptance.

.DESCRIPTION
    The build-gate must NOT assert anything that requires a runner token: the image
    ships unregistered, with no runner service. Those checks (service running,
    `gitlab-runner verify`, the 13 maintenance scheduled tasks, sshd, exporters,
    runner-metrics firewall) moved to Test-RunnerRegistered, which runs once the
    clone has self-registered from its guestinfo token.

.NOTES
    File: validation/Invoke-FinalValidation.ps1
    Requires: lib/Config.ps1, lib/Common.ps1 (dot-sourced by orchestrator)

    BUILD-gate checks (image-correctness):
      OS Build 17763 | Containers + Hyper-V(or skipped) | Docker service/version/
      isolation=process | runner binary PE | Git + GIT_SSL_NO_VERIFY | Defender
      exclusions | helper image present | Docker metrics in daemon.json |
      power plan | long paths | disk C:/E: | tool inventory | WebView2 + OpenCode
      machine config + OPENCODE_CONFIG.

    DEPLOY-gate checks (registered runner):
      runner service running | gitlab-runner verify | 13 scheduled tasks +
      Health-Check exec-limit | sshd | windows_exporter | blackbox_exporter |
      runner-metrics firewall (TCP 9252).
#>

# Shared check primitive (script scope on purpose -- PS 5.1 leaks nested function
# definitions; keeping it at script scope avoids surprises). Increments the
# script-scoped counters the gate functions reset before running.
function Invoke-Check {
    param([string]$Name, [scriptblock]$Test)
    $script:total++
    try {
        if (& $Test) { Write-Log "  [PASS] $Name"; $script:pass++ }
        else          { Write-Log "  [FAIL] $Name" -Level 'WARN'; $script:fail++; $script:ProvisioningFailed = $true }
    }
    catch { Write-Log "  [FAIL] $Name -- $_" -Level 'WARN'; $script:fail++; $script:ProvisioningFailed = $true }
}

function Write-ValidationEvent {
    # Guard the event-source lookup: on off-host/CI runs the GitLabRunner source
    # (created by Assert-Environment in Phase 1) may be absent -- Write-EventLog
    # would then throw a non-terminating error that bypasses try/catch.
    param([int]$EventId, [string]$EntryType, [string]$Message)
    try {
        if ([System.Diagnostics.EventLog]::SourceExists('GitLabRunner')) {
            Write-EventLog -LogName Application -Source 'GitLabRunner' -EventId $EventId `
                -EntryType $EntryType -Message $Message -ErrorAction Stop
        } else {
            Write-Log "  (event source 'GitLabRunner' absent -- skipping event $EventId)"
        }
    } catch { Write-LogWarn "Write-EventLog failed (non-fatal): $_" }
}

function Invoke-FinalValidation {
    # BUILD-gate -- image-correctness. Passes on an unregistered image.
    $script:pass = 0; $script:fail = 0; $script:total = 0

    Invoke-Check 'OS Build = 17763'            { [System.Environment]::OSVersion.Version.Build -eq 17763 }
    Invoke-Check 'Containers feature'          { (Get-WindowsFeature Containers).Installed }
    Invoke-Check 'Hyper-V feature OR skipped'  {
        (Get-WindowsFeature Hyper-V).Installed -or
        (Test-Path $Script:Config.HyperVSkippedMarker)
    }
    Invoke-Check 'Docker service running'      { (Get-Service docker -ErrorAction SilentlyContinue).Status -eq 'Running' }
    Invoke-Check 'Docker version = 25.0'       { (docker version --format '{{.Server.Version}}' 2>$null) -match '25\.0' }
    Invoke-Check 'Docker isolation = process'  { (docker info --format '{{.Isolation}}' 2>$null) -eq 'process' }
    Invoke-Check 'Runner binary valid'         { Test-PEBinary $Script:Config.RunnerBin }
    # First-boot registration reads the runner token+hostname from vSphere guestinfo
    # via vmtoolsd (Register-RunnerFirstBoot Get-GuestInfo). If VMware Tools isn't in
    # the image, every clone fails to self-register -- fail the BUILD here instead.
    Invoke-Check 'VMware Tools (vmtoolsd) present' {
        [bool](Get-Command vmtoolsd.exe -ErrorAction SilentlyContinue) -or
        (Test-Path 'C:\Program Files\VMware\VMware Tools\vmtoolsd.exe')
    }
    Invoke-Check 'Git available'               { Test-Path (Join-Path $Script:Config.GitDir 'cmd\git.exe') }
    Invoke-Check 'GIT_SSL_NO_VERIFY set'       { [System.Environment]::GetEnvironmentVariable('GIT_SSL_NO_VERIFY','Machine') -eq 'true' }
    Invoke-Check 'Defender exclusions'         { (Get-MpPreference).ExclusionPath -contains $Script:Config.RunnerDir }
    Invoke-Check 'Helper image present'        { (docker images $Script:Config.HelperImage --format '{{.Tag}}' 2>$null) -match 'v16.7.0' }
    Invoke-Check 'Docker metrics in daemon.json' {
        (Get-Content $Script:Config.DaemonJson -Raw -EA SilentlyContinue) -match 'metrics-addr'
    }
    Invoke-Check 'Power plan = High Perf'      { (powercfg /getactivescheme) -match '8c5e7fda' }
    Invoke-Check 'Long paths enabled'          { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem').LongPathsEnabled -eq 1 }
    Invoke-Check 'Disk free C: >= 50 GB'       { [math]::Round((Get-PSDrive C).Free / 1GB) -ge 50 }
    $dd = if (Test-Path 'E:\') { 'E' } else { $null }
    if ($dd) {
    Invoke-Check "Disk free ${dd}: >= 50 GB"    { [math]::Round((Get-PSDrive $dd).Free / 1GB) -ge 50 }
    }

    # Tool inventory: one check per row in $Config.ToolPackages (auto-extends).
    if ($Script:Config.ToolPackages) {
        foreach ($t in $Script:Config.ToolPackages) {
            $detect = $t.Detect
            Invoke-Check ("Tool: $($t.Name)")  { & $detect } | Out-Null
        }
    }

    # OpenCode + WebView2 -- machine-wide config plumbing (baked at build).
    Invoke-Check 'WebView2 installed'          {
        @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
          'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}') |
            Where-Object { Test-Path $_ } | Select-Object -First 1 |
            ForEach-Object { (Get-ItemProperty -Path $_ -Name pv -EA SilentlyContinue).pv } |
            Where-Object { $_ }
    }
    Invoke-Check 'OpenCode machine config'     { Test-Path $Script:Config.OpenCodeMachineFile }
    Invoke-Check 'OPENCODE_CONFIG env var'     {
        [System.Environment]::GetEnvironmentVariable('OPENCODE_CONFIG','Machine') -eq $Script:Config.OpenCodeMachineFile
    }

    Write-Log "Build-gate validation: $script:pass/$script:total passed, $script:fail failed"
    if ($script:fail -gt 0) {
        $Script:ProvisioningFailed = $true
        Write-ValidationEvent -EventId 9010 -EntryType Warning -Message "Build-gate: $script:fail of $script:total checks failed."
    } else {
        Write-ValidationEvent -EventId 9011 -EntryType Information -Message "Build-gate: ALL $script:total checks passed."
    }
}

function Test-RunnerRegistered {
    <#
    .SYNOPSIS  DEPLOY-gate -- confirm a registered, running runner + dependent
               services/tasks. Returns [bool] $true iff every check passes.
    .NOTES     Run at first boot / acceptance, NOT during the build (these assume
               the clone has self-registered from its guestinfo token).
    #>
    $script:pass = 0; $script:fail = 0; $script:total = 0

    Invoke-Check 'Runner service running'      { (Get-Service gitlab-runner -ErrorAction SilentlyContinue).Status -eq 'Running' }
    Invoke-Check 'Runner verify (is alive)'    { (& $Script:Config.RunnerBin verify 2>&1 | Out-String) -match 'is alive' }
    Invoke-Check 'Scheduled tasks (13 required present)' {
        $required = @('Docker-Image-Prune','Docker-Container-Cleanup','Docker-Stale-Container-Kill','Docker-Volume-Prune','Docker-BuildCache-Prune','Runner-Workspace-Cleanup','Disk-Space-Monitor','Docker-Daemon-Watchdog','Runner-Service-Watchdog','Log-Rotation','Network-Connectivity-Monitor','RDP-Audit-Logger','Health-Check')
        $have = @((Get-ScheduledTask -ErrorAction SilentlyContinue).TaskName)
        @($required | Where-Object { $have -notcontains $_ }).Count -eq 0
    }
    Invoke-Check 'Health-Check exec-limit = 2h' {
        $st = Get-ScheduledTask -TaskName 'Health-Check' -ErrorAction SilentlyContinue
        if (-not $st -or -not $st.Settings.ExecutionTimeLimit) { return $false }
        try { ([System.Xml.XmlConvert]::ToTimeSpan($st.Settings.ExecutionTimeLimit)).TotalHours -eq 2 }
        catch { $false }
    }
    Invoke-Check 'sshd service running'        { (Get-Service sshd -ErrorAction SilentlyContinue).Status -eq 'Running' }
    Invoke-Check 'windows_exporter service'    { (Get-Service windows_exporter  -EA SilentlyContinue).Status -eq 'Running' }
    Invoke-Check 'blackbox_exporter service'   { (Get-Service blackbox_exporter -EA SilentlyContinue).Status -eq 'Running' }
    Invoke-Check 'Runner metrics firewall'     {
        [bool](Get-NetFirewallRule -Name 'GitLabRunnerMetrics-In-TCP' -EA SilentlyContinue)
    }

    Write-Log "Deploy-gate validation: $script:pass/$script:total passed, $script:fail failed"
    if ($script:fail -gt 0) {
        Write-ValidationEvent -EventId 9012 -EntryType Warning -Message "Deploy-gate: $script:fail of $script:total checks failed."
        return $false
    }
    Write-ValidationEvent -EventId 9013 -EntryType Information -Message "Deploy-gate: ALL $script:total checks passed."
    return $true
}
