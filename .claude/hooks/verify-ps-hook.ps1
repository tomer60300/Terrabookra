<#
.SYNOPSIS
  PostToolUse hook glue for verify-ps.ps1.

.DESCRIPTION
  Reads the Claude Code hook payload (JSON) from stdin, pulls the edited file
  path out of .tool_input.file_path, and — only when that path ends in .ps1 —
  runs verify-ps.ps1 against it on the Windows PowerShell 5.1 engine.

  On failure it writes the verifier output to stderr and exits 2, which is the
  PostToolUse contract for "block + feed this back to Claude" so the edit can be
  self-corrected. On pass (or for non-.ps1 / unparseable payloads) it exits 0
  and does not interrupt the session.
#>
$ErrorActionPreference = 'Stop'

# Read the hook payload from stdin. No payload -> nothing to do.
$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

try {
    $payload = $raw | ConvertFrom-Json
} catch {
    # Not JSON we understand; never block on glue failure.
    exit 0
}

$path = $payload.tool_input.file_path
if ([string]::IsNullOrWhiteSpace($path)) { exit 0 }
if ($path -notmatch '\.ps1$') { exit 0 }
if (-not (Test-Path -LiteralPath $path)) { exit 0 }

$verifier = Join-Path $PSScriptRoot '..\verify-ps.ps1'

# Run the verifier as a child process so its exit code is unambiguous and its
# report (written to stdout) is captured cleanly for relay. We deliberately do
# NOT merge the child's stderr with 2>&1: across the external-process boundary
# that wraps blank lines as RemoteException objects and would pollute the text
# fed back to Claude. Any real child stderr still flows through to ours.
$output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verifier -Path $path
$code = $LASTEXITCODE
$text = ($output | Out-String)

if ($code -ne 0) {
    [Console]::Error.WriteLine($text)
    [Console]::Error.WriteLine("verify-ps failed for $path. Fix the parse error / analyzer Error above before continuing.")
    exit 2
}

[Console]::Out.Write($text)
exit 0
