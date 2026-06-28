# Base template: WS2019 LTSC from ISO with OpenSSH baked in, so every later build
# (and Packer itself) connects over SSH -- never WinRM (GPO-blocked at Kayhut).
# Air-gap: the vsphere plugin is pinned and installed from an offline mirror
# (`packer plugins install --path <mirror> github.com/hashicorp/vsphere`); the
# host sets PACKER_PLUGIN_PATH at the offline mirror. No network fetch at build.

packer {
  required_plugins {
    vsphere = {
      source  = "github.com/hashicorp/vsphere"
      version = "= 1.4.0"
    }
  }
}

source "vsphere-iso" "base" {
  vcenter_server      = var.vcenter_server
  username            = var.vcenter_username
  password            = var.vcenter_password
  insecure_connection = true

  datacenter = var.datacenter
  cluster    = var.cluster
  datastore  = var.datastore
  folder     = var.build_folder

  vm_name       = var.base_vm_name
  guest_os_type = "windows2019srvNext_64Guest"
  firmware      = "bios"

  CPUs            = var.cpus
  RAM             = var.ram_mb
  RAM_reserve_all = false

  disk_controller_type = ["lsilogic-sas"]
  storage {
    disk_size             = var.disk_mb
    disk_thin_provisioned = true
  }

  network_adapters {
    network      = var.network
    network_card = "vmxnet3"
  }

  # WS2019 LTSC ISO + the VMware Tools ISO (so Tools + vmtoolsd are present for
  # the guestinfo contract used at deploy time).
  iso_paths = [
    var.os_iso_path,
    var.vmtools_iso_path,
  ]

  # autounattend.xml drives the unattended install and enables OpenSSH Server,
  # which is how Packer's SSH communicator connects from first boot.
  floppy_files = [
    "${path.root}/autounattend.xml",
  ]

  # SSH communicator -- explicit (Packer defaults to WinRM on Windows).
  communicator = "ssh"
  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  ssh_timeout  = "4h"
  ssh_port     = 22

  # Graceful shutdown so the unattended install is committed.
  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer base shutdown\""
  shutdown_timeout = "30m"

  convert_to_template = true
}

build {
  name    = "ws2019-base"
  sources = ["source.vsphere-iso.base"]

  # Sanity: confirm SSH + OpenSSH are up. Real provisioning happens in the golden
  # build (../golden) on a clone of this template.
  provisioner "powershell" {
    inline = [
      "Write-Output \"base online: $env:COMPUTERNAME $([System.Environment]::OSVersion.VersionString)\"",
      "if ((Get-Service sshd).Status -ne 'Running') { throw 'sshd not running on base' }",
    ]
  }
}
