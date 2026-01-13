############################################################
# Proxmox Kubernetes Cluster - Terraform Main
# 3 nodes: 1 Control Plane + N Workers
############################################################

# -----------------------------
# Control Plane VM
# -----------------------------
resource "proxmox_vm_qemu" "k8s_control_plane" {
  name        = "k8s-master-01"
  target_node = var.target_node
  vmid        = 150 # maeke into variable, don't hardcode

  iso         = "${var.iso_storage}:iso/${var.ubuntu_iso}"

  cores       = var.k8s_control_plane.cores
  sockets     = 1 # maeke into variable, don't hardcode
  memory      = var.k8s_control_plane.memory

  scsihw      = "virtio-scsi-single"
  boot        = "order=scsi0;ide2;net0"

  os_type = "l26"
  agent   = 1
  # sshkeys = var.ssh_public_key # can only be used with cloud init
  disk {
    slot     = 0
    size     = "${var.k8s_control_plane.disk}G"
    type     = "scsi"
    storage  = var.disk_storage
    iothread = 1
  }

  network {
    model  = "virtio"
    bridge = var.vm_bridge
  }



  lifecycle {
    ignore_changes = [
      network,
      disk
    ]
  }
}

# -----------------------------
# Worker Nodes
# -----------------------------
resource "proxmox_vm_qemu" "k8s_workers" {
  for_each   = { for i in range(var.k8s_workers.count) : i => i }
  name       = "k8s-worker-${each.key + 1}"
  target_node = var.target_node
  vmid       = 200 + each.key

  iso        = "${var.iso_storage}:iso/${var.ubuntu_iso}"
  cores      = var.k8s_workers.cores
  memory     = var.k8s_workers.memory

  scsihw     = "virtio-scsi-single"
  boot       = "order=scsi0;ide2;net0"

  disk {
    slot    = 0
    size    = "${var.k8s_workers.disk}G"
    type    = "scsi"
    storage = var.disk_storage
    iothread = 1
  }

  network {
    model  = "virtio"
    bridge = var.vm_bridge
  }

  os_type = "l26"
  agent   = 1
  # sshkeys = var.ssh_public_key # can only be used with cloudinit

  lifecycle {
    ignore_changes = [
      network,
      disk
    ]
  }
}
