# Example tfvars -- PLACEHOLDER values. Copy to a gitignored *.auto.tfvars on the
# internal leg and fill the TODO(#12)/(#13) facts + the real runner tokens.
# `terraform plan` with these placeholders is EXPECTED to stop when the vCenter
# data sources fail to resolve the placeholder names (TODO(#12)) -- that is the
# correct signal that real placement facts are still needed.

vsphere_server   = "vcenter.example.local"     # TODO(#12)
vsphere_user     = "svc-terraform@vsphere.local" # TODO(#12)
vsphere_password = "CHANGE-ME"
datacenter       = "DC1"                         # TODO(#12)
cluster          = "Cluster1"                    # TODO(#12)
datastore        = "datastore1"                  # TODO(#12)
network          = "VM Network"                  # TODO(#12)

golden_template = "ws2019-runner-golden"

# GitLab Container Registry creds for runtime private-image pulls (delivered to
# each runner via guestinfo). Use a short-lived/least-priv deploy token.
registry_user = ""
registry_pass = ""

# TODO(#13) domain join (leave empty to deploy into a workgroup)
join_domain          = ""
domain_ou            = ""
domain_join_user     = ""
domain_join_password = ""

# Runner fleet. Tokens are SECRETS -- keep the real values in a gitignored
# *.auto.tfvars (or inject from Vault/CI), not here.
runners = {
  "runner-01" = { token = "glrt-REPLACE_ME" }
  # "runner-02" = { token = "glrt-REPLACE_ME", cpus = 16, memory_mb = 49152, data_disk_gb = 1024 }
}
