# `terraform/` — runner fleet deploy

Terraform clones runner VMs from the Packer golden template (`../packer/`) and hands each one its identity
at deploy time via vSphere `guestinfo` — the contract consumed at first boot by
`../provisioners/Register-RunnerFirstBoot.ps1`:

- `guestinfo.runner_token` — the GitLab runner auth/registration token.
- `guestinfo.runner_hostname` — the runner's hostname / `name` in `config.toml`.

No long-lived secret is baked into the image; secrets arrive at deploy time. Placement and domain-join
facts are stubbed (`# TODO(#12)` / `# TODO(#13)`) and block `terraform apply` only — never the Packer
build. Validate with `terraform validate` + `terraform fmt -check`; `terraform plan` is expected to stop
at the unresolved `TODO(#12)` facts.
