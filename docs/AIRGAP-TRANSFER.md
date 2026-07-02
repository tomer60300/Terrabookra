# Air-gap Transfer

The public leg does not carry real internal hostnames, credentials, or large
licensed binaries. The internal leg receives a versioned transfer bundle and
materializes Git LFS content locally.

## What travels

| Item | Mechanism |
| --- | --- |
| Git history | `git bundle` |
| Git LFS objects | copied `.git/lfs/objects` content-addressable store |
| Transfer metadata | `manifest.json` |
| Terraform runtime/provider mirror | staged separately under `dist/` on the internal leg |
| Packer plugins and large tools | staged internally according to the dependency inventory |

## Export on the source leg

Run from the repo worktree:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File transfer\Export-Transfer.ps1 `
  -OutDir D:\transfer `
  -Ref terraform
```

The export creates:

```text
<id>\
  <id>.bundle
  lfs\objects\...
  manifest.json
```

It also tags the exact handoff as `transfer/<id>`.

## Import on the internal leg

In the internal GitLab clone:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File transfer\Import-Transfer.ps1 `
  -InDir D:\transfer\<id> `
  -Branch terraform
```

The import script:

1. Copies the LFS CAS into `.git\lfs\objects`.
2. Fetches the bundle into `refs/transfer/<id>`.
3. Verifies the fetched SHA against the manifest.
4. Fast-forwards or creates the target branch.
5. Runs `git lfs checkout` when Git LFS is available.

## After import

Verify the internal checkout before building:

```powershell
git status -sb
git lfs status
powershell -NoProfile -ExecutionPolicy Bypass -File validation\Test-BuildInputs.ps1 -SkipRegistry
```

Populate internal-only content that the public repo does not carry:

- `dist\bin\terraform.exe`
- `dist\providers\...vmware\vra\0.17.2\windows_amd64...`
- LFS binaries under `binaries/` and `tools/`
- internal `*.auto.tfvars`
- internal Packer `*.auto.pkrvars.hcl`

The transfer bundle is code and LFS object transport. It is not a substitute for
the internal provider mirror, service credentials, or Aria catalog configuration.
