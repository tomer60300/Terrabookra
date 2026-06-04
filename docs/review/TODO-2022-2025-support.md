# TODO / Issue — Support Windows Server 2022 / 2025 hosts (deferred)

**Status:** Backlog — **do not implement now.**
**Current target (unchanged):** Windows Server **2019** host + **2019** containers, **process isolation**.
**Decision on record:** process isolation is the goal — no Hyper-V-isolation fallback.

## Why deferred
2019 is the current production target. Everything is intentionally pinned to it.
This issue captures what must change *if/when* we extend to Server 2022 (build 20348)
or 2025 (build 26100) hosts, so the constraints aren't lost.

## What blocks newer hosts today (and what to change later)

1. **Container image ↔ host build matching (the hard one).**
   With process isolation, the container base build **must equal** the host build, so the
   current `ltsc2019` images will NOT start process-isolated on a 2022/2025 host.
   - `lib/Config.ps1` → `PrePullImages`: `servercore:ltsc2019`, `windows:ltsc2019`
   - `lib/Config.ps1` → `HelperImage`: `gitlab-runner-helper:...-servercore1809`
   - `phases/Phase3-RunnerSetup.ps1` → `config.toml` `image` / `helper_image`
   Required approach (keeps process isolation): **select the image tag by host build at
   runtime** — map 17763→`ltsc2019`/`servercore1809`, 20348→`ltsc2022`, 26100→`ltsc2025` —
   and ensure the matching images exist in Harbor for each host version deployed.
   (Hyper-V isolation would sidestep matching but is explicitly out of scope per the goal.)

2. **Final validation hard-pins the OS build.**
   `validation/Invoke-FinalValidation.ps1`: `Check 'OS Build = 17763'` is an **exact** match
   and FAILs on 2022/2025. Change to a supported set `{17763, 20348, 26100}` (with the
   existing Server-SKU check), or `>= 17763`.

3. **`Assert-Environment.ps1` build expectation.**
   `-ExpectedBuild 17763`; currently WARNs on a mismatch (correct for 2019-only). When
   broadening, accept the supported-build set and only WARN on truly unknown builds.
   *(No change needed while we're 2019-only — it correctly flags non-2019 hosts.)*

4. **Tool version pins (low priority, backward-compatible).**
   Several `ToolPackages` were chosen for WS2019 (e.g. `klogg` Qt5, `WindowsTerminal` 1.18
   portable zip). They still install on newer Server, but newer builds exist if desired.

## Acceptance criteria (future)
Process-isolated CI jobs run on 2019 **and** 2022/2025 hosts, each pulling the base image
whose build matches the host, with no Hyper-V isolation and no manual per-host edits.

## Not changing now
No code in `fixes/` or the 2019 baseline is modified for this. The 2019 path stays pinned.
