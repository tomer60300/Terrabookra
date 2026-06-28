# Example var-file for the golden build -- PLACEHOLDER values so `packer validate
# -var-file=example.pkrvars.hcl` passes on a host with Packer. Copy to a real
# (uncommitted) *.auto.pkrvars.hcl on the internal leg and fill TODO(#12) facts +
# secrets. NEVER commit real vCenter/registry creds.

vcenter_server   = "vcenter.example.local"      # TODO(#12)
vcenter_username = "svc-packer@vsphere.local"    # TODO(#12) least-priv role
vcenter_password = "CHANGE-ME"
datacenter       = "DC1"                          # TODO(#12)
cluster          = "Cluster1"                     # TODO(#12)
datastore        = "datastore1"                   # TODO(#12)
network          = "VM Network"                   # TODO(#12) build portgroup

base_template_name = "ws2019-base"
repo_root          = "/abs/path/to/Runners-Infra" # absolute path to the repo tree

ssh_password = "BuildOnly-ChangeMe-Match-PKR_VAR_ssh_password!"

# GitLab Container Registry creds (injected into the Phase 3 provisioner env).
registry_user = ""
registry_pass = ""

# Optional REAL_* host overrides (decision 3). Leave empty to keep the
# *.kayhut.com aliases (resolved by hosts/DNS on the internal leg).
real_gitlab_host     = ""
real_gitlab_registry = ""
