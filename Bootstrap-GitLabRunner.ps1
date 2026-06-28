<#
.SYNOPSIS
    DEPRECATED -- retired with the Be1 (VMware Aria) orchestrator.

.DESCRIPTION
    This was the single entry point VMware Aria ("Be1") fetched from MinIO and
    re-triggered after each reboot: it self-fetched lib/phases/validation from
    MinIO (Phase 0), dot-sourced them, and dispatched the right phase by marker,
    using the 3010/0/1 exit-code contract.

    The build is now orchestrated by Packer (see packer/). Packer uploads the
    repo with its `file` provisioner and runs each phase directly via
    provisioners/Invoke-Phase.ps1, issuing `windows-restart` between phases --
    there is no MinIO self-fetch, no 3010 self-reboot, and no marker dispatch
    here. Runner identity + registration happen at first boot on the deployed
    clone (provisioners/Register-RunnerFirstBoot.ps1) from vSphere guestinfo.

    Kept as a stub for one cycle so links/automation referencing the old name
    fail loudly instead of silently running a stale flow. Safe to delete.

.NOTES
    Replaced by: packer/ (build) + provisioners/Invoke-Phase.ps1 (phase entry) +
    provisioners/Register-RunnerFirstBoot.ps1 (first-boot registration).
#>

Write-Error @'
Bootstrap-GitLabRunner.ps1 is RETIRED (Be1 orchestrator removed).
Build the image with Packer instead:
  packer build -var "repo_root=<repo>" packer/golden
Phases run via provisioners/Invoke-Phase.ps1 -Phase <1|2|3>; first-boot
registration via provisioners/Register-RunnerFirstBoot.ps1. See docs/MIGRATION-TO-TERRAFORM.md.
'@
exit 1
