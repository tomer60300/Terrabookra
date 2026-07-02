# `packer/`

Packer builds the VM images. Terraform only deploys from the published Aria
catalog item.

## Layout

| Path | Purpose |
| --- | --- |
| `base/` | Builds WS2019 from ISO with OpenSSH enabled. |
| `golden/` | Clones the base template, uploads the repo, runs Phase 1/2/3, and converts to the golden runner template. |

## Base build

```powershell
packer init packer\base
packer validate -var-file packer\base\internal.auto.pkrvars.hcl packer\base\base.pkr.hcl
packer build -var-file packer\base\internal.auto.pkrvars.hcl packer\base\base.pkr.hcl
```

## Golden build

```powershell
packer init packer\golden
packer validate -var-file packer\golden\internal.auto.pkrvars.hcl packer\golden\golden.pkr.hcl
packer build -var-file packer\golden\internal.auto.pkrvars.hcl packer\golden\golden.pkr.hcl
```

Both builders use the SSH communicator. WinRM is not part of this path.
