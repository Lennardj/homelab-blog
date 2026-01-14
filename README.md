# Homelab Blog Platform

This repository contains a **self-hosted blog platform** built on **Proxmox, Kubernetes, and Cloudflare Zero Trust**. The platform allows you to write blogs in **Markdown**, store them in **GitHub**, and build & serve them automatically using **Hugo** in Kubernetes.

## Architecture Overview


GitHub (Markdown) → Kubernetes Hugo Job → Nginx → Ingress → Cloudflare Tunnel → Zero Trust → yourdomain.com


### Features

- 3-node Kubernetes cluster on Proxmox
- Zero Trust access via Cloudflare
- Dynamic VM sizing and configuration via Terraform variables
- Cloudflare API integration for DNS and tunnel management
- Manual Hugo build job for blog deployment

### Folder Structure

homelab-blog/
├── terraform/ # Proxmox & Cloudflare infrastructure
├── ansible/ # Playbooks to bootstrap K8s cluster & platform
├── kubernetes/ # Deployments, Ingress, Hugo Job
├── blog/ # Markdown content + Hugo config
└── scripts/ # Helper scripts (deploy, trigger builds)


### Getting Started

1. **Terraform**: Create the Proxmox VMs and Cloudflare tunnel
2. **Ansible**: Bootstrap Kubernetes cluster on the VMs
3. **Kubernetes**: Deploy Ingress, cloudflared, PVC, Nginx, and Hugo Job
4. **GitHub**: Push Markdown content and trigger Hugo builds
5. Access your blog at `lennardjohn.org` via Cloudflare Zero Trust

### Requirements

- Proxmox VE
- Terraform >= 1.6
- Ansible >= 2.15
- Cloudflare account + API token
- Ubuntu ISO for VM provisioning
- SSH key for VM access

## Known Gotchas (Terraform + Proxmox)

This project includes a curated reference of non-obvious pitfalls encountered when using Terraform with Proxmox, based on real-world debugging and operational experience.

👉 See: [`terraform-proxmox-gotchas.md`](terraform/proxmox/terraform-proxmox-gotchas.md)

The document covers topics such as:
- Proxmox API token permissions
- Disk cloning and template sizing pitfalls
- Cloud-init inheritance quirks
- Serial vs VGA console behaviour
- Terraform provider limitations
