# Golden image: clone the base template, upload the repo, run Phase 1->2->3 over
# SSH (windows-restart between phases -- Packer owns sequencing; the phases no
# longer self-reboot). Phase 3 (Invoke-Phase3Install) runs the build-gate
# (Invoke-FinalValidation) at its end, so a bad image fails `packer build`.
#
# Air-gap: vsphere plugin pinned + installed from the offline mirror; the build
# VM reaches the GitLab Container Registry to pre-pull base/helper images.

packer {
  required_plugins {
    vsphere = {
      source  = "github.com/hashicorp/vsphere"
      version = "= 1.4.0"
    }
  }
}

locals {
  # Provisioner environment: REAL_* host overrides + registry creds. Empty values
  # fall through to the *.kayhut.com aliases / anonymous (Config.ps1 defaults).
  phase_env = compact([
    var.real_gitlab_host != "" ? "REAL_GITLAB_HOST=${var.real_gitlab_host}" : "",
    var.real_gitlab_registry != "" ? "REAL_GITLAB_REGISTRY=${var.real_gitlab_registry}" : "",
    var.registry_user != "" ? "REAL_GITLAB_REGISTRY_USER=${var.registry_user}" : "",
    var.registry_pass != "" ? "REAL_GITLAB_REGISTRY_PASS=${var.registry_pass}" : "",
  ])
}

source "vsphere-clone" "golden" {
  vcenter_server      = var.vcenter_server
  username            = var.vcenter_username
  password            = var.vcenter_password
  insecure_connection = true

  datacenter = var.datacenter
  cluster    = var.cluster
  datastore  = var.datastore
  folder     = var.build_folder

  template = var.base_template_name
  vm_name  = var.golden_vm_name
  CPUs     = var.cpus
  RAM      = var.ram_mb

  network_adapters {
    network      = var.network
    network_card = "vmxnet3"
  }

  communicator = "ssh"
  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  ssh_timeout  = "1h"

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer golden shutdown\""
  shutdown_timeout = "30m"

  convert_to_template = true
}

build {
  name    = "ws2019-runner-golden"
  sources = ["source.vsphere-clone.golden"]

  # 1. Upload the repo (binaries from Git LFS are materialized in the tree).
  provisioner "file" {
    source      = "${var.repo_root}/"
    destination = "C:/provision/"
  }

  # 2. Phase 1 -- system prep.
  provisioner "powershell" {
    environment_vars = local.phase_env
    inline = [
      "powershell -NoProfile -ExecutionPolicy Bypass -File C:/provision/provisioners/Invoke-Phase.ps1 -Phase 1",
    ]
  }
  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  # 3. Phase 2 -- Docker install.
  provisioner "powershell" {
    environment_vars = local.phase_env
    inline = [
      "powershell -NoProfile -ExecutionPolicy Bypass -File C:/provision/provisioners/Invoke-Phase.ps1 -Phase 2",
    ]
  }
  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  # 4. Phase 3 (build) -- runner image install + build-gate (inside the phase).
  provisioner "powershell" {
    environment_vars = local.phase_env
    inline = [
      "powershell -NoProfile -ExecutionPolicy Bypass -File C:/provision/provisioners/Invoke-Phase.ps1 -Phase 3",
    ]
  }

  # 5. Cleanup -- the deployed image is self-contained under C:\GitLab-Runner
  #    (Phase3-Install staged lib/validation/scripts there). Remove the raw repo
  #    upload (incl. .git) so source + history don't ship to production (B11).
  provisioner "powershell" {
    inline = [
      "Remove-Item -LiteralPath C:\\provision -Recurse -Force -ErrorAction SilentlyContinue",
      "if (Test-Path C:\\provision) { Write-Warning 'C:\\provision not fully removed' } else { Write-Output 'C:\\provision cleaned' }",
    ]
  }

  # 6. Manifest -- the build's record (git sha + version are stamped by
  #    Write-GoldenVersion inside Phase 3; CI promotes to 2.x.y+<gitsha>).
  post-processor "manifest" {
    output     = "${path.root}/manifest.json"
    strip_path = true
  }
}
