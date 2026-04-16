<#
.SYNOPSIS
    RDP audit logger — extracts RDP logon events to a clean log file.

.DESCRIPTION
    Runs every 5 minutes via scheduled task (RDP-Audit-Logger).
    Parses Windows Security Event Log for RDP logon events (Event ID 4624, Type 10)
    and writes them to a daily log file.

    Also captures logoff events (4634, 4647) for session duration tracking.

    History auto-rotated: files older than 30 days are deleted.

.NOTES
    File: scripts/Export-RdpAuditLog.ps1
    Log: C:\GitLab-Runner\logs\rdp\rdp-YYYY-MM-DD.log

    Prerequisites:
      Audit Logon must be enabled:
        auditpol /set /subcategory:"Logon" /success:enable /failure:enable

    Event IDs tracked:
      4624 (Type 10) — RDP logon
      4634           — Logoff
      4647           — User-initiated logoff
      21 (TerminalServices-LocalSessionManager) — RDP session logon
      23 (TerminalServices-LocalSessionManager) — RDP session logoff
#>

$ErrorActionPreference = 'Continue'
$logDir     = 'C:\GitLab-Runner\logs\rdp'
$maxAgeDays = 30
$markerFile = Join-Path $logDir '.last-check'

if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

# ── Determine time window (since last check) ─────────────────
$since = (Get-Date).AddMinutes(-6)  # default: last 6 min (5 min interval + buffer)
if (Test-Path $markerFile) {
    try { $since = Get-Date (Get-Content $markerFile -Raw).Trim() }
    catch { <# use default #> }
}

$today   = Get-Date -Format 'yyyy-MM-dd'
$logFile = Join-Path $logDir "rdp-$today.log"

# ── TerminalServices events (most reliable for RDP) ──────────
$tsEvents = @()
try {
    $tsEvents = Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
        ID        = 21, 23, 24, 25
        StartTime = $since
    } -ErrorAction SilentlyContinue
}
catch { <# no events in window #> }

foreach ($evt in $tsEvents) {
    $time = $evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss.fff')
    $xml  = [xml]$evt.ToXml()
    $user = $xml.Event.UserData.EventXML.User
    $ip   = $xml.Event.UserData.EventXML.Address
    $sid  = $xml.Event.UserData.EventXML.SessionID

    $action = switch ($evt.Id) {
        21 { 'LOGON'  }
        23 { 'LOGOFF' }
        24 { 'DISCONNECT' }
        25 { 'RECONNECT' }
        default { "EVENT-$($evt.Id)" }
    }

    $line = "[$time] [$action] User=$user IP=$ip SessionID=$sid"
    $line | Out-File $logFile -Append -Encoding UTF8
}

# ── Security log RDP logons (backup source) ──────────────────
$secEvents = @()
try {
    $secEvents = Get-WinEvent -FilterHashtable @{
        LogName   = 'Security'
        ID        = 4624
        StartTime = $since
    } -ErrorAction SilentlyContinue | Where-Object {
        # Type 10 = RemoteInteractive (RDP)
        $_.Properties[8].Value -eq 10
    }
}
catch { <# no events or access denied #> }

foreach ($evt in $secEvents) {
    $time     = $evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss.fff')
    $user     = $evt.Properties[5].Value   # TargetUserName
    $domain   = $evt.Properties[6].Value   # TargetDomainName
    $ip       = $evt.Properties[18].Value  # IpAddress

    $line = "[$time] [LOGON-SEC] User=$domain\$user IP=$ip"
    $line | Out-File $logFile -Append -Encoding UTF8
}

# ── Update marker ────────────────────────────────────────────
Get-Date -Format 'o' | Out-File $markerFile -Force -Encoding UTF8

# ── Rotate old logs ──────────────────────────────────────────
Get-ChildItem $logDir -Filter 'rdp-*.log' | Where-Object {
    $_.LastWriteTime -lt (Get-Date).AddDays(-$maxAgeDays)
} | Remove-Item -Force -ErrorAction SilentlyContinue
