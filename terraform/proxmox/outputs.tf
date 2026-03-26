############################################################
# Outputs for Ansible Inventory & Reference
############################################################

# Control Plane IP
output "control_plane_ip" {
  description = "IP address of the Kubernetes control plane VM"
  value       = [proxmox_vm_qemu.k8s_control_plane.default_ipv4_address]
}

# Worker Node IPs
output "worker_ips" {
  description = "List of IP addresses of Kubernetes worker nodes"
  value       = [for w in proxmox_vm_qemu.k8s_workers : w.default_ipv4_address]
}

# All Node IPs
output "all_nodes_ips" {
  description = "All Kubernetes node IP addresses (control + workers)"
  value = concat(
    [proxmox_vm_qemu.k8s_control_plane.default_ipv4_address],
    [for w in proxmox_vm_qemu.k8s_workers : w.default_ipv4_address]
  )
}

# Node hostnames
output "all_nodes_hostnames" {
  description = "All Kubernetes node hostnames"
  value = concat(
    [proxmox_vm_qemu.k8s_control_plane.name],
    [for w in proxmox_vm_qemu.k8s_workers : w.name]
  )
}

# Cloudflare Tunnel ID — used in cloudflared ConfigMap
output "cloudflare_tunnel_id" {
  description = "Cloudflare tunnel ID"
  value       = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
}

# Cloudflare account ID — used by Ansible to fetch tunnel token via API
output "cloudflare_account_id" {
  description = "Cloudflare account ID"
  value       = var.cloudflare_account_id
  sensitive   = true
}
