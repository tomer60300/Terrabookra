# `module/aria-vm/`

Terraform module that wraps an existing VMware Aria Service Broker catalog item.

Resources:

- `data.vra_project.this`
- `data.vra_catalog_item.runner`
- `vra_deployment.runner`

The module does not create vSphere objects directly. It passes `vm_inputs` to the
catalog item and depends on that catalog item to map inputs to the actual VM
template, hardware, network, data disk, and guestinfo settings.

Inputs are intentionally simple and Terraform 1.0.5-compatible.
