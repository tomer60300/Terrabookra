# Changelog

This branch has been refactored around the Terraform/Aria/Packer deployment
model. Older Be1, MinIO, Harbor, and review-era notes were removed from the
operational documentation path because they no longer describe the active code.

## Current branch baseline

- `Bootstrap-GitLabRunner.ps1` is a retired stub.
- Packer builds the base and golden images.
- Terraform deploys through an existing Aria Service Broker catalog item.
- Runner registration happens at first boot.
- Runtime images come from the GitLab Container Registry.
- Build/runtime binaries come from the repo and Git LFS.
- Terraform uses version `1.0.5`.
- Terraform provider is `vmware/vra` `0.17.2`.
- Docker daemon configuration intentionally avoids `storage-driver`, `dns`,
  `dns-search`, and `exec-opts` on Windows Server 2019.

## Documentation refactor

- Replaced the root README with the current branch model.
- Added a documentation index.
- Rewrote architecture, configuration, transfer, build, deployment, validation,
  operations, dependencies, and open-items docs.
- Rewrote component READMEs.
- Removed stale migration/review/signoff documents that described retired flows.

For code-level history, use Git commit history.
