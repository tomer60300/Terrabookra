---
name: ship
description: Commit and push the current Terrabookra branch after running source checks. Use when the user asks to ship, commit, or push current work.
---

# Ship current branch

This project uses the current checked-out branch as the push target. Do not
fast-forward `main` unless the user explicitly asks.

## Step 1: Inspect state

```powershell
git status -sb
git branch --show-current
git log -1 --oneline
```

Confirm the branch and changed files match the user's request.

## Step 2: Verify

For changed PowerShell files, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .claude\verify-ps.ps1 -Path <file>
```

For broad source changes, prefer:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ci\Validate-NoAliases.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Test-AriaTerraformPreflight.ps1 -SkipAriaApi
```

Report any environmental failures separately from source failures.

## Step 3: Commit

Use the project identity when possible and do not add AI-generated trailers.

```powershell
git add <paths>
git -c user.name='Tomer60300' -c user.email='Tomer60300@gmail.com' commit -m "<message>"
```

## Step 4: Push

```powershell
git push origin HEAD
```

If the branch has no upstream, push with:

```powershell
git push -u origin HEAD
```

## Step 5: Report

Return the branch, commit SHA, push target, and checks run.
