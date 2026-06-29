# Example var-file for the base build -- PLACEHOLDER values so `packer validate
# -var-file=example.pkrvars.hcl` passes on a host with Packer. Copy to a real
# (uncommitted) *.auto.pkrvars.hcl on the internal leg and fill TODO(#12) facts +
# secrets. NEVER commit real vCenter creds or the build password.

vcenter_server   = "vcenter.example.local"    # TODO(#12)
vcenter_username = "svc-packer@vsphere.local" # TODO(#12) least-priv role
vcenter_password = "CHANGE-ME"
datacenter       = "DC1"        # TODO(#12)
cluster          = "Cluster1"   # TODO(#12)
datastore        = "datastore1" # TODO(#12)
network          = "VM Network" # TODO(#12) build portgroup
os_iso_path      = "[datastore1] iso/ws2019-ltsc.iso"

ssh_password = "BuildOnly-ChangeMe-Match-PKR_VAR_ssh_password!"
