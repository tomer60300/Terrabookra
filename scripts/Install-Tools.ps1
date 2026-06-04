<#
.SYNOPSIS
    Generic, table-driven tool installer for the GitLab Runner golden image.
    HARDENED build -- proof against the 2.4.7 "staged file missing/garbage"
    failure (Cluster 1). See PATCH-NOTES.md.

.DESCRIPTION
    Iterates the $Script:Config.ToolPackages table (defined in lib/Config.ps1)
    and installs each tool that isn't already present.

    What changed vs 2.4.6/2.4.7:
      * Reverted the experimental parallel Start-Job pre-stage back to the
        canonical SERIAL loop. The parallel pre-stage (introduced after 2.4.6,
        before the 2.4.9 revalidation fix) could report "done" while the file
        never landed on disk -- the install step then ran against a missing
        file and threw "cannot find the file specified" / "Could not find
        file." Serial staging is idempotent and cheap on re-run (Detect skips
        installed tools, validated cache skips re-download).
      * New Test-StagedFile guard: a file is only handed to an installer after
        it is confirmed to exist, be non-empty, carry the correct magic bytes
        (MZ / OLE2 / PK), and NOT be a MinIO XML/HTML error body saved as a
        file. A cached file that fails validation is deleted and re-fetched.

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
# STAGED-FILE VALIDATION  (Cluster 1 guard -- script scope on purpose;
# PS 5.1 leaks nested function definitions, so keep helpers at script scope)
# ============================================================

function Get-FileKind {
    # Map InstallType -> expected on-disk file kind for magic-byte validation.
    param([hashtable]$Tool)
    switch ($Tool.InstallType) {
        'exe'        { 'exe' }
        'copy'       {
            # 'copy' is generic (drop any file at DestPath). Derive the magic
            # check from the destination extension so a future non-PE copy
            # (.crt/.yml/.cmd) isn't falsely rejected as "not an exe".
            if     ($Tool.DestPath -match '\.exe$')                  { 'exe' }
            elseif ($Tool.DestPath -match '\.msi$')                  { 'msi' }
            elseif ($Tool.DestPath -match '\.(zip|msix|msixbundle|appx)$') { 'zip' }
            else                                                     { 'any' }
        }
        'msi'        { 'msi' }
        'zip'        { 'zip' }
        'msixbundle' { 'zip' }   # msix/appx are ZIP containers (PK header)
        default      { 'any' }
    }
}

function Test-StagedFile {
    <#
    .SYNOPSIS
        $true only if the file exists, is non-empty, is NOT a MinIO/HTML error
        body, and (when Kind is known) carries the correct magic bytes.
        Reads only the first 8 bytes -- safe for multi-hundred-MB archives.
    #>
    param([string]$Path, [string]$Kind = 'any')

    if ([string]::IsNullOrEmpty($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try { if ((Get-Item -LiteralPath $Path).Length -lt 1) { return $false } }
    catch { return $false }

    $buf = New-Object byte[] 8
    $n   = 0
    $fs  = $null
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        $n  = $fs.Read($buf, 0, 8)
    } catch { return $false }
    finally { if ($fs) { $fs.Dispose() } }
    if ($n -lt 2) { return $false }

    # Reject XML/HTML error bodies saved to disk ('<' or UTF-8 BOM + '<').
    if ($buf[0] -eq 0x3C) { return $false }
    if ($n -ge 4 -and $buf[0] -eq 0xEF -and $buf[1] -eq 0xBB -and $buf[2] -eq 0xBF -and $buf[3] -eq 0x3C) { return $false }

    switch ($Kind) {
        'exe' { return ($buf[0] -eq 0x4D -and $buf[1] -eq 0x5A) }                                            # MZ
        'msi' { return ($n -ge 4 -and $buf[0] -eq 0xD0 -and $buf[1] -eq 0xCF -and $buf[2] -eq 0x11 -and $buf[3] -eq 0xE0) }  # OLE2
        'zip' { return ($buf[0] -eq 0x50 -and $buf[1] -eq 0x4B) }                                            # PK
        default { return $true }   # unknown kind: passed existence/size/not-error checks
    }
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
        $top = @(Get-ChildItem -Path $tmp -Force)
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
            if (-not (Test-StagedFile -Path $depPath -Kind 'zip')) {
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
        Write-Step "  WARN: Add-AppxProvisionedPackage failed: $($_.Exception.Message)" 'WARN'
    }
}

# ============================================================
# MAIN LOOP
# ============================================================

Write-Step '========== Install-Tools (hardened) =========='

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
        Write-Step "  Detect block raised: $($_.Exception.Message)  (treating as not installed)" 'WARN'
    }

    # 2. Stage from MinIO (idempotent + validated)
    $local = Get-LocalPath -Tool $tool
    $kind  = Get-FileKind  -Tool $tool

    if ((Test-Path $local) -and (Test-StagedFile -Path $local -Kind $kind)) {
        Write-Step "  Staged: $local (cached, validated)"
    } else {
        if (Test-Path $local) {
            Write-Step "  Cached file invalid -- deleting and re-fetching" 'WARN'
            Remove-Item $local -Force -ErrorAction SilentlyContinue
        }
        Write-Step "  Fetching s3://$($tool.S3Key) -> $local"
        if (-not (Get-S3Object -Key $tool.S3Key -OutFile $local)) {
            Write-Step "  ERROR: download failed (Get-S3Object returned false) -- key likely missing in MinIO" 'ERROR'
            $failed++
            continue
        }
    }

    # 2b. HARD GUARD -- never hand a missing / invalid file to an installer.
    #     This is what makes Cluster 1 impossible regardless of how staging ran.
    if (-not (Test-StagedFile -Path $local -Kind $kind)) {
        Write-Step "  ERROR: staged file missing or invalid ($kind) -- skipping install: $local" 'ERROR'
        $failed++
        continue
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
        Write-Step "  ERROR: $($_.Exception.Message)" 'ERROR'
        $failed++
        continue
    }

    # 4. Post-install hook
    if ($tool.PostInstall) {
        try {
            & $tool.PostInstall
        } catch {
            Write-Step "  WARN: PostInstall raised: $($_.Exception.Message)" 'WARN'
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
        Write-Step "  ERROR: Detect after install raised: $($_.Exception.Message)" 'ERROR'
        $failed++
    }
}

Write-Step ''
Write-Step "========== Install-Tools COMPLETE =========="
Write-Step "  Installed: $installed   Skipped: $skipped   Failed: $failed"

exit $(if ($failed -gt 0) { 1 } else { 0 })
