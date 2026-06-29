# --- vCenter connection + placement -- the TODO(#12) fact set ---------------
# These have no real defaults: `terraform plan` is EXPECTED to stop here until
# the internal-leg facts are supplied (via a gitignored *.auto.tfvars or env).

variable "vsphere_server" {
  type = string # TODO(#12) vCenter FQDN
}

variable "vsphere_user" {
  type = string # TODO(#12) svc-terraform (least-priv role, runner folder only)
}

variable "vsphere_password" {
  type      = string
  sensitive = true
}

variable "allow_unverified_ssl" {
  type    = bool
  default = true # self-signed internal vCenter
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
  type = string # TODO(#12) runner portgroup
}

variable "vm_folder" {
  type    = string
  default = "runners"
}

variable "golden_template" {
  type    = string
  default = "ws2019-runner-golden" # produced by ../packer/golden
}

# --- Domain join -- the TODO(#13) fact set ----------------------------------
# Leave join_domain = "" to skip the domain join (workgroup). Fill on the
# internal leg to land runners in the right OU.
variable "join_domain" {
  type    = string
  default = "" # TODO(#13) e.g. kayhut.com
}

variable "domain_ou" {
  type    = string
  default = "" # TODO(#13) target OU distinguished name
}

variable "domain_join_user" {
  type    = string
  default = "" # TODO(#13) least-priv join account
}

variable "domain_join_password" {
  type      = string
  default   = ""
  sensitive = true
}

# --- Runner fleet -----------------------------------------------------------
# Map of runner-name -> sizing + token. POV default: 24 vCPU / 64 GB / 2 TB data
# disk (E:), on top of the template's ~100 GB C:.
#
# NOTE: NOT marked sensitive -- Terraform `for_each` rejects a sensitive value.
# The token IS a secret: source this map from a gitignored *.auto.tfvars or, on
# the internal leg, from Vault/CI-injected vars. The token reaches each clone via
# guestinfo (extra_config), never baked into the image.
variable "runners" {
  type = map(object({
    token        = string
    cpus         = optional(number, 24)
    memory_mb    = optional(number, 65536)
    data_disk_gb = optional(number, 2048)
  }))
  default = {}
}

# --- GitLab Container Registry creds for RUNTIME pulls (delivered via guestinfo) -
# The SYSTEM runner service logs in with these at first boot so it can pull
# private images at job time. Prefer a short-lived/least-priv deploy token --
# guestinfo is readable in-guest. Empty => anonymous (only pre-baked images).
variable "registry_user" {
  type    = string
  default = ""
}

variable "registry_pass" {
  type      = string
  default   = ""
  sensitive = true
}
