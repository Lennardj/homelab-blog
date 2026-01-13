# Terraform - Proxmox & Cloudflare

This folder contains the Terraform code for provisioning:

1. **Proxmox VMs** for a 3-node Kubernetes cluster
2. **Cloudflare DNS & Tunnel** for Zero Trust access

### Folder Structure

terraform/
├── proxmox/ # VM provisioning Tunnel and DNS setup
│ ├── main.tf
│ ├── variables.tf
│ ├── providers.tf
│ └── outputs.tf

