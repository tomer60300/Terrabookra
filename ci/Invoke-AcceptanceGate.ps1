<#
.SYNOPSIS
    ACCEPTANCE-GATE -- exercise a freshly deployed runner end to end.

.DESCRIPTION
    Decision (2): the acceptance gate is "deploy one runner and run representative
    pipelines", as opposed to the build-gate (image-correctness). Run in the CI
    `image-test` stage AFTER Terraform deploys one runner from the just-built
    template and the runner self-registers from its guestinfo token.

    Steps:
      1. Wait for the runner to register + come online in GitLab (the deploy-gate
         Test-RunnerRegistered runs in-guest at first boot; here we confirm from
         the GitLab side via the API).
      2. Trigger 2-3 representative pipelines (incl. a heavy pytest-xdist job) on
         the test project, pinned to the new runner's tag.
      3. Assert every pipeline exits 0 AND total wall-time <= the Be1 baseline.

    Inputs (CI variables):
      GITLAB_API_URL, GITLAB_API_TOKEN  -- to query pipelines/jobs
      ACCEPTANCE_PROJECT_ID             -- the representative test project
      RUNNER_TAG                        -- tag the new runner registered with
      BE1_BASELINE_SECONDS              -- wall-time budget (Be1 reference)

    NOTE: the concrete pipeline triggers + timing assertions are wired on the lab
    vCenter / internal GitLab where a real runner + test project exist. This
    script is the contract + scaffold; the marked TODO is the lab step.

.NOTES
    File: ci/Invoke-AcceptanceGate.ps1
    PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [string]$GitLabApiUrl        = $env:GITLAB_API_URL,
    [string]$GitLabApiToken      = $env:GITLAB_API_TOKEN,
    [string]$AcceptanceProjectId = $env:ACCEPTANCE_PROJECT_ID,
    [string]$RunnerTag           = $env:RUNNER_TAG,
    [int]$Be1BaselineSeconds     = $(if ($env:BE1_BASELINE_SECONDS) { [int]$env:BE1_BASELINE_SECONDS } else { 0 })
)

$ErrorActionPreference = 'Stop'

if (-not $GitLabApiUrl -or -not $GitLabApiToken -or -not $AcceptanceProjectId) {
    Write-Error 'Acceptance gate needs GITLAB_API_URL, GITLAB_API_TOKEN, ACCEPTANCE_PROJECT_ID.'
    exit 2
}

# TODO(lab): implement against the internal GitLab once a test project + a live
# runner exist. The shape:
#   - POST /projects/:id/pipeline (ref + variables) for each representative case.
#   - Poll GET /projects/:id/pipelines/:pid until status in {success,failed}.
#   - Fail this script (exit 1) if any pipeline != success, or if the summed
#     wall-time exceeds $Be1BaselineSeconds (when > 0).
Write-Host "Acceptance gate scaffold: project=$AcceptanceProjectId tag=$RunnerTag baseline=${Be1BaselineSeconds}s"
Write-Warning 'Acceptance-gate pipeline triggers are a lab step (internal GitLab) -- not yet implemented here.'
Write-Warning 'Wire the representative pipelines + timing assertion on the lab vCenter; see docs/MIGRATION-STATUS.md.'

# Until implemented, do NOT signal a false PASS in real CI: exit non-zero so the
# image-test stage is visibly pending implementation rather than silently green.
exit 3
