<#
.SYNOPSIS
    Apply the distinctive "runner VM" desktop theme so a runner is visually
    obvious vs a local workstation. Cosmetic + best-effort: NEVER throws and
    always exits 0, so it is safe to run as a non-blocking scheduled task.

.DESCRIPTION
    Applies to the CURRENT user's HKCU -- run it in the interactive user's
    context. Re-run periodically: an org GPO / auto-setting reverts personal
    appearance, so a logon + interval scheduled task re-asserts it.

      Accent     : mint light (#AAF0D1) on taskbar + title bars (light theme)
      Background : solid dark teal (#204038) -- no wallpaper image
      Cursor     : arrow_r.cur (distinct pointer)

.PARAMETER CursorPath  Path to the pointer .cur. Default %SystemRoot%\Cursors\arrow_r.cur

.NOTES
    Run as: the interactive user (scheduled task, INTERACTIVE principal).
    PowerShell 5.1, Windows Server 2019. Safe: every step guarded; exit 0 always.
#>
param(
    [string]$CursorPath = "$env:SystemRoot\Cursors\arrow_r.cur"
)
$ErrorActionPreference = 'Continue'

function Log  { param([string]$m,[string]$l='INFO') Write-Output ("[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'),$l,$m) }
function U32  { param([uint32]$v) [BitConverter]::ToInt32([BitConverter]::GetBytes($v),0) }   # uint32 -> DWord bit pattern
function SetReg {
    param([string]$Path,[string]$Name,$Value,[string]$Type='DWord')
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    } catch { Log "WARN set ${Path}\${Name}: $($_.Exception.Message)" 'WARN' }
}

Log '========== Set-RunnerTheme =========='

# Native helpers for the live refresh (best-effort).
$native = $false
try {
    if (-not ([System.Management.Automation.PSTypeName]'RunnerTheme.Native').Type) {
        Add-Type -Namespace RunnerTheme -Name Native -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Auto)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, string pvParam, uint fWinIni);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int SetSysColors(int cElements, int[] lpaElements, uint[] lpaRgbValues);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.IntPtr lpdwResult);
"@ -ErrorAction Stop
    }
    $native = $true
} catch { Log "WARN native helpers unavailable: $($_.Exception.Message)" 'WARN' }

# --- 1. Light theme + accent on taskbar / title bars --------------------------
$pers = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
SetReg $pers 'AppsUseLightTheme'    1
SetReg $pers 'SystemUsesLightTheme' 1
SetReg $pers 'ColorPrevalence'      1
SetReg $pers 'EnableTransparency'   0

# --- 2. Mint-light accent (#AAF0D1) -------------------------------------------
$accentABGR = U32 0xFFD1F0AA   # AccentColor / AccentColorMenu  (0xAABBGGRR)
$accentARGB = U32 0xFFAAF0D1   # ColorizationColor              (0xAARRGGBB)
$dwm = 'HKCU:\SOFTWARE\Microsoft\Windows\DWM'
SetReg $dwm 'AccentColor'              $accentABGR
SetReg $dwm 'ColorizationColor'        $accentARGB
SetReg $dwm 'ColorizationAfterglow'    $accentARGB
SetReg $dwm 'EnableWindowColorization' 1
SetReg $dwm 'ColorPrevalence'          1
$acc = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent'
SetReg $acc 'AccentColorMenu' $accentABGR
SetReg $acc 'StartColorMenu'  $accentABGR

# --- 3. Solid dark-teal desktop background (#204038), no wallpaper ------------
SetReg 'HKCU:\Control Panel\Colors'  'Background'     '32 64 56' 'String'
SetReg 'HKCU:\Control Panel\Desktop' 'Wallpaper'      ''         'String'
SetReg 'HKCU:\Control Panel\Desktop' 'WallpaperStyle' '0'        'String'
SetReg 'HKCU:\Control Panel\Desktop' 'TileWallpaper'  '0'        'String'

# --- 4. Distinct cursor (arrow_r.cur) -----------------------------------------
$cur = [Environment]::ExpandEnvironmentVariables($CursorPath)
if (Test-Path $cur) {
    SetReg 'HKCU:\Control Panel\Cursors' 'Arrow' $CursorPath 'ExpandString'
    SetReg 'HKCU:\Control Panel\Cursors' ''      'Runner'    'String'        # scheme name
    Log "  cursor set: $cur"
} else {
    Log "  cursor file not found ($cur) -- skipping cursor (non-fatal)" 'WARN'
}

# --- 5. Apply live (best-effort; registry already persisted for next logon) ---
if ($native) {
    try { [void][RunnerTheme.Native]::SystemParametersInfo(0x0014, 0, '', 0x03) } catch {}      # SPI_SETDESKWALLPAPER ''
    try { [void][RunnerTheme.Native]::SetSysColors(1, [int[]]@(1), [uint32[]]@(0x00384020)) } catch {}  # COLOR_BACKGROUND 0x00BBGGRR
    try { [void][RunnerTheme.Native]::SystemParametersInfo(0x0057, 0, $null, 0x03) } catch {}    # SPI_SETCURSORS
    try { $r=[IntPtr]::Zero; [void][RunnerTheme.Native]::SendMessageTimeout([IntPtr]0xFFFF, 0x001A, [IntPtr]::Zero, 'ImmersiveColorSet', 0x0002, 1000, [ref]$r) } catch {}
    Log '  applied live (wallpaper/colors/cursors refreshed)'
}

Log '========== Set-RunnerTheme COMPLETE =========='
exit 0
