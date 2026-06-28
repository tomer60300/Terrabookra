# Migrating off Be1 → Packer + Terraform — Best-Practice Design

> **Implementation status (`terraform` branch):** the code-side of this design is implemented — see
> `docs/MIGRATION-STATUS.md`. Decisions taken during implementation that supersede parts of the design
> text below:
> - **Artifacts: MinIO is RETIRED.** Build binaries travel via **Git LFS** and are read from the repo
>   tree Packer uploads (`Copy-RepoFile` / `Install-Local*`). (§2/§4 still say "MinIO stays" — overridden.)
> - **Images: Harbor is RETIRED → GitLab Container Registry.** (§2/§4 still say "Harbor stays" — overridden.)
> - **Aliases by name resolution, not byte-substitution** (§5.3-adjacent): `Config.ps1` reads `$env:REAL_*`
>   with the `*.kayhut.com` alias as default; `Substitute-Aliases` is removed; `Validate-NoAliases` is
>   repurposed to the alias-by-resolution invariant.
> - **Phase refactor = thin** (§5.1 option A): phases stay intact, de-rebooted/de-chained; Packer owns
>   `windows-restart`. **Communicator = SSH** baked into the base (§5.2). The thin orchestrator is
>   `provisioners/Invoke-Phase.ps1`; first-boot registration is `provisioners/Register-RunnerFirstBoot.ps1`.

**Scope:** replace VMware Aria ("Be1") as the orchestrator of the air-gapped
Windows Server 2019 GitLab-Runner golden image, with a HashiCorp toolchain, done
to best practice and with a controlled, low-risk migration. Target environment is
unchanged: air-gapped, WS2019 LTSC, SSH as the in-guest control plane (WinRM is
GPO-blocked). (Artifact-plane note: this text's MinIO/Harbor references are
superseded by the status banner above.)

---

## 1. The central reframe

Be1 quietly does **two different jobs**:

1. **Builds the golden image** — an imperative, multi-reboot, in-guest workflow
   (Phase 1 → reboot → Phase 2 → reboot → Phase 3), driven by the exit-code
   contract (`3010`=reboot, `0`=done, `1`=fail) and the phase-marker resume logic.
2. **Manages VM lifecycle** — clone from template, power on, re-trigger, and
   ultimately produce a reusable image.

Terraform is a *declarative infrastructure* tool. It has no native "run a script,
reboot the guest, reconnect, resume" model. Bolting that onto Terraform means
`remote-exec` provisioners wrapped around your reboot loop — and HashiCorp's own
documentation calls provisioners a **last resort**. So "move to Terraform" should
really be read as:

> **Packer builds the image. Terraform deploys runners from it.**

This is the idiomatic split and it maps almost perfectly onto what Be1 already
does. Everything below assumes it.

The single most important consequence: **the golden image becomes the contract.**
As long as a new producer (Packer) emits an image that passes the same validation,
the producer is swappable — which is exactly what makes the migration safe.

---

## 2. Big picture — target architecture

Five planes, each with one clear owner:

```
        ┌─────────────────────────────────────────────────────────────┐
 SOURCE │  Git (internal GitLab)                                        │
        │  PowerShell phases · Packer templates · Terraform modules     │
        └───────────────┬───────────────────────────────────────────────┘
                        │  commit
        ┌───────────────▼───────────────┐     ┌───────────────────────────┐
   CI   │  GitLab CI/CD                  │     │  ARTIFACT PLANE (keep)     │
        │  validate → build → test →     │◄────┤  MinIO (S3) binaries       │
        │  promote → deploy              │     │  Harbor   images           │
        └───────┬───────────────┬────────┘     └───────────────────────────┘
                │ packer build  │ terraform apply
        ┌───────▼──────────┐  ┌─▼───────────────────┐   ┌──────────────────┐
 BUILD  │  Packer          │  │ Terraform           │   │ IDENTITY/SECRETS  │
        │  vsphere-clone   │  │ vsphere_virtual_    │   │ Vault (or sealed  │
        │  SSH communicator│  │   machine (clones   │◄──┤ sensitive vars)   │
        │  runs Phase 1-3  │  │   from template)    │   │ least-priv vCenter│
        │  windows-restart │  │ registers runners   │   │ gMSA in-guest     │
        │  → versioned     │  └─────────────────────┘   └──────────────────┘
        │    template +    │           │ DEPLOY (fleet of runners)
        │    manifest      │           ▼
        └──────────────────┘     [ runner-01 ] [ runner-02 ] ...
```

- **Source plane** — Git holds *everything* together: the in-guest PowerShell,
  the Packer template(s), the Terraform modules. One commit, one versioned unit.
- **Artifact plane** — MinIO + Harbor stay. They work, they're air-gapped, and
  both Packer (build-time) and the deployed runners (run-time) consume from them.
- **Build plane (Packer)** — produces a *versioned, validated, immutable* vSphere
  template plus a manifest (git SHA, tool versions, build date, content hashes).
- **Deploy plane (Terraform)** — clones runner VMs from that template, customizes
  per-host (name, domain join, runner token), registers them. Declarative fleet.
- **Identity/secrets plane** — Vault (or sealed sensitive variables) for secrets;
  least-privilege vCenter service accounts; scoped in-guest identity; secured
  Terraform state.

---

## 3. Best-practice principles driving the design

- **Separate build from run.** Packer builds; Terraform runs. Never mutate a live
  runner — to change it, rebuild the image and redeploy. This is the immutable-
  infrastructure shift, and it's the biggest mental change from the Be1 model
  (which provisions a VM *in place*). It also kills config drift — e.g. the
  "org auto-setting reverts the runner theme" problem becomes "rebuild fixes it."
- **The image is versioned and reproducible.** Every build carries a manifest:
  `2.x.y+<gitsha>`, tool versions, content hashes. This also fixes the version-
  label confusion you already hit (VERSION vs GoldenImageVersion vs bootstrap) —
  the manifest becomes the single source of truth, emitted by the build, not
  hand-edited.
- **No secrets in version control.** The placeholder-edited `Config.ps1` and the
  duplicated bootstrap keys go away; secrets are externalized and injected.
- **Least privilege everywhere** — vCenter roles, in-guest identity, secret scope.
- **Air-gap is a first-class constraint**, not an afterthought: offline provider
  and plugin mirrors, vendored binaries, pinned inputs.
- **Validation is a build gate, not a runtime hope.** `Invoke-FinalValidation`
  moves left: it fails the *build*, so a bad image never ships.
- **Reversible until cutover.** The old path stays alive until the new one proves
  equivalence (strangler-fig — see §8).

---

## 4. What you keep, change, and retire

| Today (Be1) | Disposition | New owner |
|---|---|---|
| Phase 1–3 PowerShell, Install-*, Docker config, runner registration, observability, WT/theme/OpenCode | **Keep** (≈90% reused) | Packer provisioners |
| MinIO artifacts, Harbor images, SigV4 fetch | **Keep** | Packer build-time + runner run-time |
| `Invoke-FinalValidation`, `Test-Dependencies`, `Assert-Environment` | **Keep, move left** | Packer build gate / pre-build |
| Be1 exit-code contract (`3010`/`0`/`1`) | **Retire** | Packer build success/fail |
| Self-reboot (`shutdown /r`) + power-cycle loop | **Replace** | `windows-restart` provisioner |
| Phase-marker dispatch / resume | **Simplify** (keep short-term for idempotency) | Packer step ordering |
| Clone / power / convert-to-template | **Replace** | Packer (build), Terraform (deploy) |
| Be1 trigger + USB hand-off for the build | **Replace** | GitLab CI pipeline |
| Creds in `Config.ps1` / bootstrap | **Replace** | Vault / sensitive vars + guestinfo |

The headline: **you are replacing the wrapper, not the work.** The provisioning
content is orchestrator-independent.

---

## 5. The hard parts (where the real effort is)

### 5.1 The reboot/phase model — the crux

Today the guest reboots *itself* (`exit 3010`), Be1 repowers it, the bootstrap
re-runs, and marker dispatch resumes the right phase. Packer inverts this: the
`windows-restart` provisioner sits *between* `powershell` provisioner steps —
Packer issues the restart, waits for the guest to come back over the communicator,
and continues. No `3010`, no self-reboot, no external repower.

Two refactor depths:

- **(A) Thin** — keep the phase scripts intact; strip only the Be1 exit-code /
  self-reboot glue; let Packer drive the restarts between Phase 1/2/3 calls.
  Lowest risk, preserves tested logic. **Recommended first.**
- **(B) Decompose** — break phases into discrete provisioner steps in the Packer
  HCL, drop markers entirely. Cleaner and more Packer-native, more rework. Evolve
  to this later.

### 5.2 Communicator: WinRM vs SSH — your specific landmine

Packer's *default* Windows communicator is WinRM — which is **GPO-blocked at
Kayhut** (the reason you went SSH). So Packer must use the **SSH communicator**,
over the OpenSSH the image already installs. That creates a chicken-and-egg: Packer
needs a communicator to run the script that installs SSH.

Resolution (recommended): **bake OpenSSH into the base template once**, so Packer
connects via SSH from the first boot. Alternatives: enable SSH via `autounattend.xml`
/ vSphere guest customization / `guestinfo` before Packer's main provisioners, or
get a build-window WinRM GPO exception scoped to the build OU/network. Baking SSH
into the base is cleanest and matches your SSH-first control-plane stance.

### 5.3 Secrets & "proper permissions" — the part you asked for

- **vCenter identities** — two dedicated service accounts, each with a *custom
  least-privilege role* scoped to specific folders/clusters:
  - `svc-packer`: clone, customize, power, snapshot, mark-as-template — on a build
    folder/resource pool only.
  - `svc-terraform`: clone-from-template, power, network attach — on the runner
    folder only.
  - Neither is vCenter Administrator.
- **Secrets backend** — **Vault** is the best-practice target (short-lived dynamic
  creds, audit, revocation). If Vault is too heavy to run air-gapped initially,
  the pragmatic interim is Packer/Terraform **`sensitive` variables** sourced from
  GitLab CI masked/protected variables, with per-host secrets injected via vSphere
  **`guestinfo`** (so nothing is baked into the image). Either way, the
  placeholder-edit pattern and duplicated bootstrap keys are eliminated.
- **In-guest identity** — replace "SYSTEM + domain-admin SSH password" with a
  scoped provisioning account or **gMSA**; the runner service runs least-priv; the
  registry/MinIO creds are delivered just-in-time and not persisted in the image.
- **Terraform state** — it stores secrets and topology in plaintext. Use an
  encrypted, access-controlled, locking backend (air-gapped: MinIO as the S3
  backend with SSE + tight ACLs). Mark outputs `sensitive`.
- **Clean image** — no long-lived secret is ever baked into the template; secrets
  arrive at *deploy* time via `guestinfo`/cloud-init. The image stays publishable.

### 5.4 Air-gap plumbing

- Mirror Terraform providers (`terraform providers mirror`) and Packer plugins
  into an internal filesystem/registry; pin versions.
- Vendor the Packer and Terraform binaries themselves.
- CI runners need the vСenter, MinIO, Harbor network paths the build requires.

---

## 6. CI/CD pipeline (managing the build itself)

GitLab CI stages, end to end:

1. **validate** — PSScriptAnalyzer + your quote/brace checks, `Validate-NoAliases`,
   `Test-Dependencies` dry-run (now env-var driven — already done).
2. **packer validate** — template lint.
3. **build** — `packer build` produces the template + manifest; manifest pushed to
   MinIO/registry. Reuses Phase 1–3 over SSH with `windows-restart`.
4. **image-test** — smoke test: Terraform deploys *one* runner from the fresh
   image into a sandbox, runs `Invoke-FinalValidation` + a real CI job, destroys.
5. **promote** — tag the image "released" (`2.x.y+<gitsha>`).
6. **deploy** (manual gate) — `terraform apply` to roll the fleet.

Versioning is emitted by the build (manifest), not hand-maintained — closing the
version-label gap you already flagged.

---

## 7. Managing the shift well (change management)

This is as important as the technical design. The approach is **strangler-fig +
equivalence-gated cutover** — never a big-bang.

**Guiding rule:** the golden image is the contract. Be1 and Packer both build *the
same image from the same scripts*; you cut over only when the Packer image is
provably equivalent.

Phased rollout, each phase shippable and reversible:

1. **Spike (lab).** Packer builds the image in a non-prod vCenter using the SSH
   communicator and the existing phase scripts. Temp creds, no secrets refactor
   yet. Goal: prove the reboot/resume model under `windows-restart`.
2. **Equivalence gate.** Define "done" objectively: the Packer image passes the
   *same* `Invoke-FinalValidation`, and a component/config diff against a
   Be1-built image is clean. Automate this comparison.
3. **Harden.** Add the secrets backend, least-priv vCenter roles, and air-gap
   mirrors. Re-run the equivalence gate.
4. **Parallel run.** CI builds via *both* Be1 and Packer; compare every build.
   Deploy a **canary** runner from the Packer image and route real jobs to it.
5. **Cutover.** Switch the "blessed" image source to Packer. Keep Be1 as a
   documented fallback for N weeks (rollback = re-bless the last Be1 image).
6. **Fleet to Terraform.** Migrate runner *deployment* to Terraform (rebuild
   rather than import, to land on clean immutable hosts).
7. **Decommission Be1.** Remove the exit-`3010` / self-reboot code and (optionally)
   the marker dispatch; archive the Aria blueprints.

**Risk register (track explicitly):** SSH/WinRM chicken-and-egg; air-gap provider
availability; Terraform-state secret exposure; domain-join timing during build;
rollback path (always keep last-known-good template + the Be1 path until step 7).

**Reversibility:** every step before cutover is reversible because the image is the
contract — if the Packer image regresses, you re-bless the Be1 image and nothing
downstream changes.

**Success metrics:** zero secrets in Git; least-priv verified (no Administrator
service accounts); reproducible build (manifest-stable); build time; manual steps
removed; equivalence test green on every build.

---

## 8. Open decisions (with my recommendation)

| Decision | Options | Recommendation |
|---|---|---|
| Primary build tool | Terraform-only vs Packer+Terraform | **Packer+Terraform** |
| Phase refactor depth | Thin vs decompose | **Thin first**, evolve to decompose |
| Windows communicator | WinRM exception vs SSH | **SSH**, baked into base template |
| Secrets backend | Vault vs sealed sensitive vars | **Vault** if runnable air-gapped; else sensitive vars + `guestinfo` interim |
| Keep phase markers? | Keep vs drop | **Keep short-term** for idempotency, drop at decompose |
| Fleet deploy timing | Now vs after image cutover | **After** image cutover |

---

## 9. Effort shape (relative, not a quote)

The work is **front-loaded and orchestration-heavy, not a rewrite**:

- **Heavy:** SSH-communicator bootstrap, air-gap provider/plugin mirroring, the
  secrets + least-privilege redesign.
- **Light:** reusing the Phase 1–3 scripts, moving validation into a build gate.
- **Order:** spike → equivalence gate → harden (secrets/permits/air-gap) →
  parallel → cutover → fleet → decommission. Each is independently valuable, so
  you get signal early and can pause between any two.

The provisioning logic you've spent this whole effort hardening is the part that
carries straight over. The migration is about giving it a better, least-privilege,
reproducible home.
