# Base-template build variables. Secrets come from env (PKR_VAR_*) or a
# *.auto.pkrvars.hcl that is NOT committed. vCenter placement facts are the same
# TODO(#12) set Terraform needs -- left without defaults on purpose so a build
# fails fast until they are supplied on the internal leg.

variable "vcenter_server" {
  type = string # TODO(#12) vCenter FQDN
}

variable "vcenter_username" {
  type = string # TODO(#12) svc-packer (least-priv role)
}

variable "vcenter_password" {
  type      = string
  sensitive = true
}

variable "datacenter" {
  type = string # TODO(#12)
}

variable "cluster" {
  type = string # TODO(#12)
}

variable "datastore" {
  type = string # TODO(#12)
}

variable "network" {
  type = string # TODO(#12) build portgroup
}

variable "build_folder" {
  type    = string
  default = "packer-build"
}

variable "base_vm_name" {
  type    = string
  default = "ws2019-base"
}

variable "os_iso_path" {
  type = string # datastore path to the WS2019 LTSC ISO
}

variable "vmtools_iso_path" {
  type    = string
  default = "[] /vmimages/tools-isoimages/windows.iso"
}

# SSH communicator (Packer's Windows default is WinRM -- GPO-blocked at Kayhut, so
# SSH is set explicitly). These match the local admin created by autounattend.xml.
variable "ssh_username" {
  type    = string
  default = "Administrator"
}

variable "ssh_password" {
  type      = string
  sensitive = true
}

variable "cpus" {
  type    = number
  default = 4
}

variable "ram_mb" {
  type    = number
  default = 8192
}

variable "disk_mb" {
  type    = number
  default = 102400 # C: ~100 GB
}
