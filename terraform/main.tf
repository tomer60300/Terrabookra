provider "vsphere" {
  vsphere_server       = var.vsphere_server
  user                 = var.vsphere_user
  password             = var.vsphere_password
  allow_unverified_ssl = var.allow_unverified_ssl
}

# --- Placement data sources (TODO(#12): resolve once real names are supplied) -
data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

data "vsphere_datastore" "ds" {
  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_compute_cluster" "cluster" {
  name          = var.cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "net" {
  name          = var.network
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "template" {
  name          = var.golden_template
  datacenter_id = data.vsphere_datacenter.dc.id
}

# --- Runner fleet: clone-from-template, identity via guestinfo ---------------
resource "vsphere_virtual_machine" "runner" {
  for_each = var.runners

  name             = each.key
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.ds.id

  num_cpus = each.value.cpus
  memory   = each.value.memory_mb

  guest_id  = data.vsphere_virtual_machine.template.guest_id
  scsi_type = data.vsphere_virtual_machine.template.scsi_type
  firmware  = data.vsphere_virtual_machine.template.firmware

  network_interface {
    network_id   = data.vsphere_network.net.id
    adapter_type = data.vsphere_virtual_machine.template.network_interface_types[0]
  }

  # C: -- inherited from the template's system disk.
  disk {
    label            = "disk0"
    size             = data.vsphere_virtual_machine.template.disks[0].size
    thin_provisioned = data.vsphere_virtual_machine.template.disks[0].thin_provisioned
    eagerly_scrub    = data.vsphere_virtual_machine.template.disks[0].eagerly_scrub
  }

  # E: -- runner data disk (builds/cache/docker-data). $DataDrive resolves to E:
  # at first boot, so config.toml volumes + docker data-root land here.
  disk {
    label       = "disk1"
    size        = each.value.data_disk_gb
    unit_number = 1
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id

    customize {
      windows_options {
        computer_name         = each.key
        # TODO(#13): domain join. Empty join_domain => workgroup (no join).
        workgroup             = var.join_domain == "" ? "WORKGROUP" : null
        join_domain           = var.join_domain != "" ? var.join_domain : null
        domain_ou             = var.domain_ou != "" ? var.domain_ou : null
        domain_admin_user     = var.domain_join_user != "" ? var.domain_join_user : null
        domain_admin_password = var.domain_join_password != "" ? var.domain_join_password : null
      }

      network_interface {}
    }
  }

  # The first-boot contract consumed by provisioners/Register-RunnerFirstBoot.ps1.
  extra_config = {
    "guestinfo.runner_token"    = each.value.token
    "guestinfo.runner_hostname" = each.key
  }

  lifecycle {
    # Identity is delivered once at clone time; ignore drift on guestinfo so a
    # token rotation is a deliberate taint/replace, not silent on every apply.
    ignore_changes = [extra_config]
  }
}
