# Terrabookra — Cluster fixes (drop-in for 2.4.7i)

**Context:** GitHub `main` is **2.4.6**; you run **2.4.7i** on the private GitLab.
These three scripts are **drop-in replacements** for your `scripts/` folder.
I did **not** touch `lib/Common.ps1` (your 2.4.7 downloader) or
`Phase3-RunnerSetup.ps1` — the fixes are consumer-side, so your download
rewrite and orchestrator are **not regressed**.

> Diff against your 2.4.7i copies before dropping in. The OpenCode and
> Observability scripts were unchanged across the 2.4.x fix stack, so a
> whole-file swap is safe; Install-Tools reverts the experimental parallel
> tool pre-stage (see Cluster 1).

---

## Cluster 1 — Install-Tools.ps1 (14/14 tools failed)

**Root cause.** 2.4.7's parallel `Start-Job` tool pre-stage landed *before*
the 2.4.9 "cached-file revalidation" fix. A pre-stage job could report
success while the file never reached disk, so the install step ran against a
missing file → `cannot find the file specified` (exe) / `Could not find file`
(zip). Identical across all 14 tools = shared staging path, not per-tool.

**Fix.**
- Reverted to the **serial** staging loop (canonical 2.4.6 behaviour;
  idempotent, cheap on re-run).
- New `Test-StagedFile` guard: a file is handed to an installer **only** after
  it exists, is non-empty, carries the right magic bytes (`MZ` / `OLE2` / `PK`),
  and is **not** a MinIO XML/HTML error body saved as a file. Invalid cache is
  deleted and re-fetched. Install-on-missing-file is now impossible.

**Apply:** copy to `C:\GitLab-Runner\scripts\Install-Tools.ps1` (+ repo `scripts/`).

**Verify:**
```
& powershell -NoProfile -ExecutionPolicy Bypass -File C:\GitLab-Runner\scripts\Install-Tools.ps1
```
Expect: `Installed: 14   Skipped: 0   Failed: 0`.
If you see `download failed ... key likely missing in MinIO` → the object
isn't in the bucket (see **MinIO prerequisite** below).

---

## Cluster 2 — Install-OpenCode.ps1 (exit 6)

**Root cause.** `Test-OpenCodeInstalled` checked only 4 fixed paths. Phase 3
runs as **SYSTEM**, so the per-user (NSIS) install lands in the SYSTEM profile
(`C:\Windows\System32\config\systemprofile\AppData\Local\Programs\...`) and/or
a versioned subfolder — both missed → false exit 6 even though the install
succeeded.

**Fix.** Detection now (1) reads the install path from the **Uninstall registry
key**, then (2) recursively sweeps every plausible root **including the SYSTEM
profile**. Added a 3 s settle after the NSIS run and a clear failure dump.

**Apply:** copy to `C:\GitLab-Runner\scripts\Install-OpenCode.ps1`.

**Verify:**
```
& powershell -NoProfile -ExecutionPolicy Bypass -File C:\GitLab-Runner\scripts\Install-OpenCode.ps1
[Environment]::GetEnvironmentVariable('OPENCODE_CONFIG','Machine')
Test-Path C:\ProgramData\opencode\opencode.jsonc
```
Expect: `OpenCode installed at <path>`, env var = `C:\ProgramData\opencode\opencode.jsonc`, config present.

> **Multi-user note:** a per-user install under the SYSTEM profile isn't usable
> by your SSH login users. If you want OpenCode available to everyone, install
> it machine-wide (e.g. `/S /D=C:\Program Files\opencode`, or per-machine via
> `--allusers` if the installer supports it). Detection above already covers
> `C:\Program Files\opencode`.

---

## Cluster 3 — Install-Observability.ps1 (windows_exporter + blackbox_exporter FAIL)

**Root cause.** Cascade. Exporter binaries were never staged: Phase 3 (3.14)
stages with `Get-S3Object … | Out-Null` (result discarded), so on failure
Install-Observability logged "not staged" and never created the service.
`blackbox_exporter` additionally needs `C:\Tools\nssm.exe`, which **Install-Tools**
(Cluster 1) was supposed to provide. The `OpenCode machine config` and
`OPENCODE_CONFIG` validation FAILs were pure cascade from Cluster 2.

**Fix.**
- **Self-staging fallback:** if the MSI/ZIP isn't on disk, locate `Config.ps1` +
  `Common.ps1` and download it from the configured S3 keys (with magic-byte
  validation).
- Services started with a **retry+verify** loop and explicit `[PASS]`/`[FAIL]`
  lines instead of fire-and-forget.
- Explicit guard if `nssm.exe` is missing (→ fix Cluster 1 first).

**Apply:** copy to `C:\GitLab-Runner\scripts\Install-Observability.ps1`.

**Verify:**
```
Get-Service windows_exporter, blackbox_exporter | Format-Table Name, Status
```
Expect both `Running`. The two OpenCode validation checks pass once Cluster 2 is fixed.

---

## MinIO prerequisite (verify before re-running)

The code can't install what isn't in the bucket. You confirmed only the
`tools/opencode/` and `binaries/` objects exist. Confirm these are uploaded
(`gitlab-runner-golden` bucket):

- All 14 `ToolPackages` keys — `tools/winrar/…`, `tools/nssm/nssm-2.24.zip`,
  `tools/sysinternals/…`, `tools/notepadpp/…`, `tools/winmerge/…`,
  `tools/baretail/…`, `tools/klogg/…`, `tools/everything/…`, `tools/wiztree/…`,
  `tools/systeminformer/…`, `tools/eventlook/…`, `tools/wireshark/…`,
  `tools/chrome/…`, `tools/terminal/…`
- `tools/observability/windows_exporter-0.30.5-amd64.msi`
- `tools/observability/blackbox_exporter-0.27.0.windows-amd64.zip`

If any are missing, upload via `binaries-staging/Fetch-Binaries.ps1` → MinIO.

**Order:** Install-Tools must run **before** Install-Observability (nssm).
Phase 3 already sequences 3.12 → 3.14.
