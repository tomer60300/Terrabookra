# Documentation Index

The docs in this branch describe the current Terraform/Aria/Packer source model.
Older Be1, MinIO, Harbor, and migration-review notes were removed from the
operational documentation path because they no longer match the code.

## Core docs

| Document | Use it for |
| --- | --- |
| [Architecture](ARCHITECTURE.md) | End-to-end system model and runtime flow. |
| [Configuration](CONFIGURATION.md) | Where each configurable value belongs. |
| [Dependencies](DEPENDENCIES.md) | Required offline binaries, providers, images, and services. |
| [Air-gap transfer](AIRGAP-TRANSFER.md) | Moving code and Git LFS objects into the internal network. |
| [Build](BUILD.md) | Building base and golden images with Packer. |
| [Deployment](DEPLOYMENT.md) | Deploying runner VMs through Terraform and Aria. |
| [Validation](VALIDATION.md) | CI, build-gate, deploy-gate, and local checks. |
| [Operations](OPERATIONS.md) | Logs, scheduled tasks, fleet scripts, and troubleshooting. |
| [Open items](OPEN-ITEMS.md) | Contracts that require the internal lab/live Aria to close. |

## Component docs

Each major folder has a short README that explains its role:

- [`binaries/`](../binaries/README.md)
- [`dist/`](../dist/README.md)
- [`fleet/`](../fleet/README.md)
- [`lib/`](../lib/README.md)
- [`packer/`](../packer/README.md)
- [`phases/`](../phases/README.md)
- [`provisioners/`](../provisioners/README.md)
- [`scripts/`](../scripts/README.md)
- [`terraform/`](../terraform/README.md)
- [`transfer/`](../transfer/README.md)
- [`validation/`](../validation/README.md)

## Source of truth order

When docs and code disagree, trust the code in this order:

1. `lib/Config.ps1`
2. `packer/*`
3. `phases/*`
4. `provisioners/*`
5. `terraform/*` and `module/aria-vm/*`
6. `validation/*`
7. `.gitlab-ci.yml`

Docs are descriptive; they do not replace the CI gates.
