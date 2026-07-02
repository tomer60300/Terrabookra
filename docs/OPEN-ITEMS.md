# Open Items

These are not documentation gaps. They are source-observable contracts that need
the internal lab or live Aria/vSphere environment to close.

## OI-1: Aria catalog guestinfo mapping

Terraform passes `vm_inputs` to an existing Aria catalog item. The repo cannot
prove that the catalog maps those inputs into VMware guestinfo or machine env.

Required for first boot:

- `runner_token`

Recommended:

- `runner_hostname`
- `registry_user`
- `registry_pass`

Closure: inspect the real catalog item schema and run a sandbox deploy that
confirms `vmtoolsd --cmd "info-get guestinfo.runner_token"` succeeds in-guest.

## OI-2: VMware Tools availability

First boot prefers VMware guestinfo through `vmtoolsd.exe`. The build-gate now
checks for VMware Tools before shipping the golden image, but the base image or
platform still needs to provide it.

Closure: confirm VMware Tools is installed in the base/golden image or install it
explicitly during the base Packer build.

## OI-3: Data disk contract

First boot initializes the first non-USB raw disk as `E:`. If no suitable disk is
present, the runner falls back to C:.

Closure: confirm the Aria catalog attaches the intended raw data disk and decide
whether fallback to C: should remain allowed in production.

## OI-4: Acceptance gate implementation

`ci/Invoke-AcceptanceGate.ps1` is currently a scaffold and exits non-zero so it
cannot create a false green signal.

Closure: wire it to the internal GitLab test project, trigger representative
pipelines, and enforce the wall-time and success criteria.

## OI-5: Live end-to-end validation

The following cannot be proven from the public/dev leg:

- Packer base build against vCenter.
- Packer golden build through both restarts.
- first-boot registration on a real clone.
- Docker Windows process-isolation job execution.
- Terraform apply against live Aria.

Closure: run the internal pipeline and capture the build, deploy, and first-job
evidence before promoting a template broadly.
