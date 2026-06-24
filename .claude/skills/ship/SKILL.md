---
name: ship
description: Release ritual for Terrabookra — statically verify changed .ps1 files, commit as Tomer60300 (no Claude trailer), push the hardening branch, then fast-forward main. Use when the user says "ship", "ship it", "release", or asks to commit-and-push the current work following the project's git flow.
---

# ship — Terrabookra release ritual

Run the project's commit/push flow exactly. **Idempotent:** every step is safe to
re-run; if there is nothing to do (clean tree, branch already pushed, main already
even), say so and move on. **Print each step** as you go: `STEP n: ...` then the
command and its result.

This is the **public dev leg** — GitHub only; MinIO/Harbor/Be1/GitLab are
unreachable, so verification is static. PowerShell 5.1 is the target: verify with
`powershell.exe`, never `pwsh`.

## STEP 1 — Verify changed .ps1 files (static)

List changed/added `.ps1` files vs the merge target:

```
git diff --name-only --diff-filter=d HEAD -- "*.ps1"
git diff --name-only --diff-filter=d --cached -- "*.ps1"
git ls-files --others --exclude-standard -- "*.ps1"
```

For each unique path, run the verifier on the 5.1 engine and check the exit code:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .claude\verify-ps.ps1 -Path <file>
```

If any file exits non-zero (parse error or analyzer Error), **STOP** — report the
findings and do not commit. If no `.ps1` changed, print "no .ps1 changes to verify"
and continue.

## STEP 2 — Be on the hardening branch

```
git rev-parse --abbrev-ref HEAD
```

If not on `hardening/2.4.6-cluster-and-review`, check it out
(`git checkout hardening/2.4.6-cluster-and-review`). All commits land here, never
directly on `main`.

## STEP 3 — Commit as Tomer60300 (no trailer)

Stage the intended files, then commit with the project identity and **no** Claude /
Co-Authored-By / "Generated with" trailer. Write the message to a temp file and use
`-F` so the body is exact:

```
git add <paths>
git -c user.name='Tomer60300' -c user.email='Tomer60300@gmail.com' commit -F <msgfile>
```

If `git status` shows nothing staged/changed, print "nothing to commit" and skip to
STEP 5 (the branch may just need pushing).

## STEP 4 — Push the hardening branch

**Export the push token first.** The repo is **public**, so reads / `ls-remote`
succeed even with a bad or empty token — a failed *push* is the only real signal,
and the credential helper sends an **empty password** if the token var isn't
exported. So, before pushing, ensure the GitHub token is exported in the
environment (this session's var is `GITHUB_TOKEN`):

```
# bash:        export GITHUB_TOKEN=...    # PowerShell: $env:GITHUB_TOKEN = '...'
git push origin hardening/2.4.6-cluster-and-review
```

Confirm the push reports an updated ref (or "Everything up-to-date"). Do **not**
conclude "token revoked" from a failed push alone — re-check that the token is
exported and non-empty first.

## STEP 5 — Fast-forward main

`main` only ever fast-forwards from the hardening branch — never a separate commit,
never a merge commit:

```
git checkout main
git merge --ff-only hardening/2.4.6-cluster-and-review
git push origin main
git checkout hardening/2.4.6-cluster-and-review
```

If the fast-forward is refused, the branches have diverged — stop and report;
do not force.

## STEP 6 — Report

Print: branch, the commit SHA(s) that landed, push results for both refs, and that
`main` is even with the hardening branch. End by leaving the working branch checked
out as `hardening/2.4.6-cluster-and-review`.
