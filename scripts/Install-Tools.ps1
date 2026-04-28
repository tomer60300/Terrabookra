<#
.SYNOPSIS
    Generic, table-driven tool installer for the GitLab Runner golden image.

.DESCRIPTION
    Iterates the $Script:Config.ToolPackages table (defined in lib/Config.ps1)
    and installs each tool that isn't already present. Replaces the old
    hardcoded tool-deployment block in Phase 3 step 3.12.

    Each tool is a hashtable with these fields:

      Name        : human-readable label, used in log lines and validation
      S3Key       : MinIO object key (relative to the bucket)
      StageDir    : where the file is staged on disk before install
      InstallType : one of 'exe', 'msi', 'zip', 'copy', 'msixbundle'
      InstallArgs : array of args passed to the installer (silent flags)
      ExtractTo   : (zip only) destination directory for extraction
      DestPath    : (copy only) where to place the single binary
      Dependencies: (msixbundle only) array of S3 keys for required .appx
      Detect      : scriptblock returning $true when the tool is installed
      PostInstall : optional scriptblock run after a successful install

    Idempotent: any tool whose Detect block returns truthy is skipped.

.PARAMETER ConfigPath
    Path to lib/Config.ps1. If omitted, expects $Script:Config to already be
    loaded (when run from the orchestrator) or auto-locates it.

.NOTES
    File:        scripts/Install-Tools.ps1
    Run as:      Administrator
    Called from: Phase 3 step 3.12
    Idempotent:  Yes
#>

param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Continue'

function Write-Step {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Output "[$ts] [$Level] $Message"
}

# ============================================================
# CONFIG / S3 BOOTSTRAP -- when running standalone
# ============================================================
if (-not $Script:Config) {
    if (-not $ConfigPath) {
        $candidates = @(
            (Join-Path $PSScriptRoot '..\bootstrap\lib\Config.ps1'),
            'C:\GitLab-Runner\lib\Config.ps1'
        )
        $ConfigPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $ConfigPath) { throw 'Cannot locate lib/Config.ps1.' }
    . $ConfigPath
}

# Get-S3Object lives in lib/Common.ps1; ensure it's loaded
if (-not (Get-Command Get-S3Object -ErrorAction SilentlyContinue)) {
    $commonPath = Join-Path (Split-Path $ConfigPath) 'Common.ps1'
    if (Test-Path $commonPath) { . $commonPath }
}

# ============================================================
# INSTALLER PRIMITIVES
# ============================================================

function Get-LocalPath {
    param([hashtable]$Tool)
    if ($Tool.StageDir) {
        if (-not (Test-Path $Tool.StageDir)) {
            New-Item -Path $Tool.StageDir -ItemType Directory -Force | Out-Null
        }
        return Join-Path $Tool.StageDir (Split-Path $Tool.S3Key -Leaf)
    }
    return $Tool.DestPath
}

function Install-Exe {
    param([hashtable]$Tool, [string]$LocalPath)
    Write-Step "  Running: $LocalPath $($Tool.InstallArgs -join ' ')"
    $proc = Start-Process -FilePath $LocalPath -ArgumentList $Tool.InstallArgs `
                          -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        Write-Step "  WARN: $($Tool.Name) exit code = $($proc.ExitCode)" 'WARN'
    }
}

function Install-Msi {
    param([hashtable]$Tool, [string]$LocalPath)
    $msiArgs = @('/i', "`"$LocalPath`"", '/quiet', '/norestart')
    if ($Tool.InstallArgs) { $msiArgs += $Tool.InstallArgs }
    Write-Step "  Running: msiexec.exe $($msiArgs -join ' ')"
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs `
                          -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -notin 0,3010) {
        Write-Step "  WARN: $($Tool.Name) msiexec exit = $($proc.ExitCode)" 'WARN'
    }
}

function Install-Zip {
    param([hashtable]$Tool, [string]$LocalPath)
    if (-not $Tool.ExtractTo) { throw "$($Tool.Name): InstallType=zip requires ExtractTo." }
    if (-not (Test-Path $Tool.ExtractTo)) {
        New-Item -Path $Tool.ExtractTo -ItemType Directory -Force | Out-Null
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $tmp = Join-Path $env:TEMP "tools-extract-$([Guid]::NewGuid().ToString('N'))"
    New-Item -Path $tmp -ItemType Directory -Force | Out-Null
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($LocalPath, $tmp)
        # If the zip contains a single top-level dir, descend into it before copying
        $top = Get-ChildItem -Path $tmp -Force
        $source = if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $top[0].FullName } else { $tmp }
        Get-ChildItem -Path $source -Force |
            Copy-Item -Destination $Tool.ExtractTo -Recurse -Force
        Write-Step "  Extracted to $($Tool.ExtractTo)"
    } finally {
        Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-Copy {
    param([hashtable]$Tool, [string]$LocalPath)
    if (-not $Tool.DestPath) { throw "$($Tool.Name): InstallType=copy requires DestPath." }
    $destDir = Split-Path $Tool.DestPath -Parent
    if (-not (Test-Path $destDir)) {
        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
    }
    Copy-Item -Path $LocalPath -Destination $Tool.DestPath -Force
    Write-Step "  Copied to $($Tool.DestPath)"
}

function Install-MsixBundle {
    param([hashtable]$Tool, [string]$LocalPath)
    # Stage dependencies (Microsoft.UI.Xaml, Microsoft.VCLibs) first
    $depPaths = @()
    if ($Tool.Dependencies) {
        foreach ($depKey in $Tool.Dependencies) {
            $depPath = Join-Path $Tool.StageDir (Split-Path $depKey -Leaf)
            if (-not (Test-Path $depPath)) {
                Get-S3Object -Key $depKey -OutFile $depPath | Out-Null
            }
            $depPaths += $depPath
        }
    }
    # Provisioned package = installed for all current and future user profiles
    $params = @{
        Online      = $true
        PackagePath = $LocalPath
        SkipLicense = $true
    }
    if ($depPaths.Count -gt 0) { $params.DependencyPackagePath = $depPaths }
    try {
        Add-AppxProvisionedPackage @params -ErrorAction Stop | Out-Null
        Write-Step "  Provisioned $($Tool.Name) for all users"
    } catch {
        Write-Step "  WARN: Add-AppxProvisionedPackage failed: $_" 'WARN'
    }
}

# ============================================================
# MAIN LOOP
# ============================================================

Write-Step '========== Install-Tools =========='

if (-not $Script:Config.ToolPackages) {
    Write-Step '  No ToolPackages defined in Config -- nothing to do.' 'WARN'
    exit 0
}

$installed = 0
$skipped   = 0
$failed    = 0

foreach ($tool in $Script:Config.ToolPackages) {
    Write-Step ''
    Write-Step "[$($tool.Name)]"

    # 1. Detection -- skip if already installed
    try {
        if (& $tool.Detect) {
            Write-Step "  Already installed -- skip"
            $skipped++
            continue
        }
    } catch {
        Write-Step "  Detect block raised: $_  (treating as not installed)" 'WARN'
    }

    # 2. Stage from MinIO
    $local = Get-LocalPath -Tool $tool
    if (-not (Test-Path $local)) {
        Write-Step "  Fetching s3://$($tool.S3Key) -> $local"
        if (-not (Get-S3Object -Key $tool.S3Key -OutFile $local)) {
            Write-Step "  ERROR: download failed" 'ERROR'
            $failed++
            continue
        }
    } else {
        Write-Step "  Staged: $local (cached)"
    }

    # 3. Install per InstallType
    try {
        switch ($tool.InstallType) {
            'exe'         { Install-Exe         -Tool $tool -LocalPath $local }
            'msi'         { Install-Msi         -Tool $tool -LocalPath $local }
            'zip'         { Install-Zip         -Tool $tool -LocalPath $local }
            'copy'        { Install-Copy        -Tool $tool -LocalPath $local }
            'msixbundle'  { Install-MsixBundle  -Tool $tool -LocalPath $local }
            default       { throw "Unknown InstallType '$($tool.InstallType)'" }
        }
    } catch {
        Write-Step "  ERROR: $_" 'ERROR'
        $failed++
        continue
    }

    # 4. Post-install hook
    if ($tool.PostInstall) {
        try {
            & $tool.PostInstall
        } catch {
            Write-Step "  WARN: PostInstall raised: $_" 'WARN'
        }
    }

    # 5. Verify with Detect
    try {
        if (& $tool.Detect) {
            Write-Step "  OK"
            $installed++
        } else {
            Write-Step "  ERROR: Detect returns false after install" 'ERROR'
            $failed++
        }
    } catch {
        Write-Step "  ERROR: Detect after install raised: $_" 'ERROR'
        $failed++
    }
}

Write-Step ''
Write-Step "========== Install-Tools COMPLETE =========="
Write-Step "  Installed: $installed   Skipped: $skipped   Failed: $failed"

exit $(if ($failed -gt 0) { 1 } else { 0 })
