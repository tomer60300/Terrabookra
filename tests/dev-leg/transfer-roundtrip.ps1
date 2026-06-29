#!/usr/bin/env pwsh
# Real round-trip of transfer/Export-Transfer.ps1 + Import-Transfer.ps1 using
# actual git + git-lfs (no mocks). Proves bundle + LFS CAS + SHA-verify + checkout.
$ErrorActionPreference = 'Stop'
$REPO = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$pass = 0; $fail = 0
function ok($c, $m) { if ($c) { Write-Host "  [PASS] $m"; $script:pass++ } else { Write-Host "  [FAIL] $m"; $script:fail++ } }

$root = Join-Path ([IO.Path]::GetTempPath()) ("xfer-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$src = Join-Path $root 'src'; $dst = Join-Path $root 'dst'; $out = Join-Path $root 'usb'
New-Item -ItemType Directory -Path $src, $dst, $out -Force | Out-Null

# --- build a source repo with a code file + an LFS-tracked binary ---
git -C $src init -q -b terraform
git -C $src config user.email t@e.com; git -C $src config user.name t
git -C $src lfs install --local 2>&1 | Out-Null
Set-Content (Join-Path $src '.gitattributes') "*.bin filter=lfs diff=lfs merge=lfs -text"
Set-Content (Join-Path $src 'code.ps1') "Write-Output 'hi'"
$bytes = [byte[]]::new(5000); for ($i=0;$i -lt 5000;$i++){ $bytes[$i] = $i % 256 }
[IO.File]::WriteAllBytes((Join-Path $src 'blob.bin'), $bytes)
git -C $src add -A; git -C $src commit -q -m "init with lfs blob"
$srcSha = (git -C $src rev-parse terraform).Trim()
$lfsCount = (Get-ChildItem (Join-Path $src '.git/lfs/objects') -Recurse -File -EA SilentlyContinue).Count

Write-Host "`n== transfer round-trip (real git + git-lfs) =="
ok ($lfsCount -ge 1) "source has $lfsCount LFS object(s) in CAS"

# --- EXPORT ---
& $REPO/transfer/Export-Transfer.ps1 -RepoRoot $src -OutDir $out -Id t1 -Ref terraform -TimeStamp 20260629 2>&1 | Out-Null
$xdir = Join-Path $out 't1'
ok (Test-Path (Join-Path $xdir 't1.bundle')) "bundle created"
ok (Test-Path (Join-Path $xdir 'manifest.json')) "manifest created"
$man = Get-Content (Join-Path $xdir 'manifest.json') -Raw | ConvertFrom-Json
ok ($man.sha -eq $srcSha) "manifest SHA matches source ($($srcSha.Substring(0,7)))"
ok (($man.lfsObjects | Measure-Object).Count -ge 1) "manifest lists LFS object(s)"
ok ((Get-ChildItem (Join-Path $xdir 'lfs/objects') -Recurse -File).Count -eq $lfsCount) "CAS copied into transfer"

# --- IMPORT into a fresh repo ---
git -C $dst init -q -b main
git -C $dst config user.email t@e.com; git -C $dst config user.name t
git -C $dst lfs install --local 2>&1 | Out-Null
& $REPO/transfer/Import-Transfer.ps1 -InDir $xdir -RepoRoot $dst -Branch terraform 2>&1 | Out-Null
$dstSha = (git -C $dst rev-parse terraform 2>$null)
ok ($dstSha -and $dstSha.Trim() -eq $srcSha) "imported branch at the exact source SHA"
$blob = Join-Path $dst 'blob.bin'
ok (Test-Path $blob) "LFS binary present after checkout"
$isPointer = (Get-Content $blob -TotalCount 1 -EA SilentlyContinue) -match 'git-lfs'
ok ((Test-Path $blob) -and -not $isPointer -and ((Get-Item $blob).Length -gt 1000)) "binary materialized from CAS (not a pointer)"

# --- tamper: a manifest SHA mismatch must be rejected ---
$bad = Join-Path $out 't1bad'; Copy-Item $xdir $bad -Recurse
$m2 = Get-Content (Join-Path $bad 'manifest.json') -Raw | ConvertFrom-Json
$m2.sha = '0' * 40; ($m2 | ConvertTo-Json) | Set-Content (Join-Path $bad 'manifest.json')
$threw = $false
try { & $REPO/transfer/Import-Transfer.ps1 -InDir $bad -RepoRoot $dst -Branch x 2>&1 | Out-Null } catch { $threw = $true }
ok ($threw) "import rejects a manifest SHA mismatch"

Write-Host "`nPASS=$pass FAIL=$fail"
Remove-Item $root -Recurse -Force -EA SilentlyContinue
exit ([int]($fail -gt 0))
