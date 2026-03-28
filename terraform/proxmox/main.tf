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
  clone      = var.vm_template
  full_clone = true

  os_type          = "cloud-init"
  ipconfig0        = "ip=${var.master_ip}/24,gw=${var.vm_gateway}"
  nameserver       = "8.8.8.8 8.8.4.4"
  ciuser           = "lennard"
  cipassword       = var.cloudinit_password
  ciupgrade        = false
  automatic_reboot = true
  sshkeys          = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOcZXl91NXf+09ntGlxlLEmg4a+I/yvXgFGfkm2sKgNc ljohn@Lennard-John-PC"
  memory           = var.k8s_control_plane.memory

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
    cores   = var.k8s_control_plane.cores
    sockets = var.vm_sockets
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


  clone      = var.vm_template
  full_clone = true

  os_type          = "cloud-init"
  ipconfig0        = "ip=${var.worker_ips[each.key]}/24,gw=${var.vm_gateway}"
  nameserver       = "8.8.8.8 8.8.4.4"
  ciuser           = "lennard"
  cipassword       = var.cloudinit_password
  ciupgrade        = false
  automatic_reboot = true
  sshkeys          = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOcZXl91NXf+09ntGlxlLEmg4a+I/yvXgFGfkm2sKgNc ljohn@Lennard-John-PC"

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
    sockets = var.vm_sockets
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
