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
  vmid        = 150
  description = "Master node for the kubernetes cluster"

  # Cloud init template
  clone      = "ubuntu-cloud" # make into variable, don't hardcode
  full_clone = true




  os_type          = "cloud-init"
  ipconfig0        = "ip=dhcp"
  ciuser           = "lennard"
  cipassword       = var.cloudinit-password
  ciupgrade        = true
  automatic_reboot = true

  memory = var.k8s_control_plane.memory

  agent    = 1
  scsihw   = "virtio-scsi-single"
  boot     = "c"
  bootdisk = "scsi0"
  disk {
    slot    = "scsi0"
    storage = var.disk_storage
    size    = "${var.k8s_control_plane.disk}G"
  }

  disk {
    slot    = "ide2"
    type    = "cloudinit"
    storage = var.disk_storage
  }
  cpu {
    # already baked into tamplate but it is a good idea to set them
    cores   = var.k8s_control_plane.cores
    sockets = 2 # make into variable, don't hardcode

  }
  network {
    id     = 0
    model  = "virtio"
    bridge = var.vm_bridge
  }

  serial {
    id   = 0
    type = "socket"
  }

  vga {
    type = "serial0"
  }
}

# -----------------------------
# Worker Nodes
# -----------------------------
resource "proxmox_vm_qemu" "k8s_workers" {
  for_each    = { for i in range(var.k8s_workers.count) : i => i }
  name        = "k8s-worker-${each.key + 1}"
  target_node = var.target_node
  vmid        = 200 + each.key
  description = "Worker nodes node for the kubernetes cluster"


  clone      = "ubuntu-cloud" # make into variable, don't hardcode
  full_clone = true

  os_type          = "cloud-init"
  ipconfig0        = "ip=dhcp"
  ciuser           = "lennard"
  cipassword       = var.cloudinit-password
  ciupgrade        = true
  automatic_reboot = true


  agent    = 1
  scsihw   = "virtio-scsi-single"
  boot     = "c"
  bootdisk = "scsi0"


  memory = var.k8s_workers.memory
  disk {
    slot    = "scsi0"
    storage = var.disk_storage
    size    = "${var.k8s_workers.disk}G"
  }

  disk {
    slot    = "ide2"
    type    = "cloudinit"
    storage = var.disk_storage
  }

  cpu {
    cores   = var.k8s_workers.cores
    sockets = 2
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = var.vm_bridge
  }

  serial {
    id   = 0
    type = "socket"
  }

  vga {
    type = "serial0"
  }
}
