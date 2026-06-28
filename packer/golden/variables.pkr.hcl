# Golden-image build variables. Clones the base template, uploads the repo, runs
# Phase 1->2->3 over SSH with windows-restart between, and gates on
# Invoke-FinalValidation (build-gate). Produces a GENERIC, UNREGISTERED template.

variable "vcenter_server" {
  type = string # TODO(#12)
}

variable "vcenter_username" {
  type = string # TODO(#12) svc-packer
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

variable "base_template_name" {
  type    = string
  default = "ws2019-base"
}

variable "golden_vm_name" {
  type    = string
  default = "ws2019-runner-golden"
}

# Absolute path to the repo working tree that gets uploaded into the guest. The
# build VM consumes binaries from binaries/ + tools/ (Git LFS materialized). No
# default: the `file` provisioner resolves relative paths against the working
# directory, so pass an absolute path (see example.pkrvars.hcl).
variable "repo_root" {
  type = string
}

variable "ssh_username" {
  type    = string
  default = "Administrator"
}

variable "ssh_password" {
  type      = string
  sensitive = true
}

# GitLab Container Registry creds, injected into the Phase 3 provisioner env so
# the registry login + image pre-pull work WITHOUT baking creds into the image.
variable "registry_user" {
  type    = string
  default = ""
}

variable "registry_pass" {
  type      = string
  default   = ""
  sensitive = true
}

# Optional REAL_* host overrides (decision 3: alias-by-resolution). Passed into
# the provisioner env so the build talks to the real internal hosts while the
# committed source keeps *.kayhut.com aliases.
variable "real_gitlab_host" {
  type    = string
  default = ""
}

variable "real_gitlab_registry" {
  type    = string
  default = ""
}

variable "cpus" {
  type    = number
  default = 8
}

variable "ram_mb" {
  type    = number
  default = 16384
}
