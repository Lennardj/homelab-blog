# --- Proxmox ---
variable "proxmox_api_url" {
  description = "Proxmox API endpoint"
  type        = string
}

variable "proxmox_api_token_id" {
  description = "Proxmox API token ID (user@realm!tokenname)"
  type        = string
  sensitive   = true
}

variable "proxmox_api_token_secret" {
description = "Proxmox API token secret (uuid)"
  type        = string
  sensitive   = true
}

variable "proxmox_tls_insecure" {
  description = "Allow insecure TLS to Proxmox API"
  type        = bool
  default     = true
}



variable "target_node" {
  description = "Proxmox node name"
  type        = string
  default     = "pve"
}

variable "vm_bridge" {
  description = "Network bridge"
  type        = string
  default     = "vmbr0"
}

variable "iso_storage" {
  description = "Storage containing ISO"
  type        = string
  default     = "local"
}

variable "disk_storage" {
  description = "torage that supports VM disks (e.g. local-lvm, zfs, ceph)"
  type        = string
  default     = "local-lvm"
}

variable "ubuntu_iso" {
  description = "Ubuntu ISO filename"
  type        = string
  default     = "ubuntu-24.04.3-live-server-amd64.iso"
}




variable "ssh_public_key" {
  description = "SSH public key for VM access"
  type        = string
}

variable "k8s_control_plane" {
  description = "Control plane VM sizing"
  type = object({
    cores  = number
    memory = number
    disk   = number
  })
  default = {
    cores = 4
    memory = 4096
    disk = 50
  }
}

variable "k8s_workers" {
  description = "Worker node configuration"
  type = object({
    count  = number
    cores  = number
    memory = number
    disk   = number
  })
  default = {
    cores = 2
    count = 2
    memory = 2048
    disk = 35
  }
}


# --- Cloud Flare ---
variable "cloudflare_api_token" {
  description = "Cloudflare API token"
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID"
  type        = string
}

variable "domain_name" {
  description = "Root domain name"
  type        = string
}
