# Homelab Blog Platform
![infra diagram](./infra.png)

This repository contains a **self-hosted, production-style platform** built on **Proxmox, Kubernetes, and Cloudflare Zero Trust**.

It automates the full lifecycle of:
- Infrastructure provisioning  
- Kubernetes cluster bootstrap  
- Platform services deployment  
- Application delivery (**WordPress + MariaDB**)

> Designed to demonstrate **DevOps, Platform Engineering, and Solution Architecture principles** on homelab infrastructure.

---

## 🏗️ Architecture Diagram

```mermaid
flowchart TB

User["User Browser"]
Cloudflare["Cloudflare Tunnel + Zero Trust"]
DNS["DNS / Domain"]

MetalLB["MetalLB LoadBalancer"]
Ingress["NGINX Ingress Controller"]

WordPress["WordPress"]
Database["MariaDB"]

subgraph Kubernetes Cluster
    KubeAPI["Kubernetes API"]
    Calico["Calico CNI"]
    Storage["Local Path Provisioner"]
    Metrics["Metrics Server"]
    Prometheus["Prometheus"]
    Grafana["Grafana"]
end

subgraph Automation
    Terraform["Terraform"]
    Ansible["Ansible"]
end

subgraph Infrastructure
    Proxmox["Proxmox Hypervisor"]
    VMs["Kubernetes VMs"]
    CloudInit["Cloud-init Templates"]
end

User --> DNS
DNS --> Cloudflare
Cloudflare --> MetalLB
MetalLB --> Ingress
Ingress --> WordPress
WordPress --> Database

WordPress --> KubeAPI
Prometheus --> KubeAPI
Grafana --> Prometheus

Terraform --> Proxmox
Proxmox --> VMs
CloudInit --> VMs
Ansible --> VMs
Ansible --> KubeAPI

VMs --> KubeAPI
KubeAPI --> Calico
KubeAPI --> Storage
KubeAPI --> Metrics
```

### Infrastructure Pipeline

---

## ⚙️ Key Features

### ☸️ Kubernetes Platform
- 3-node Kubernetes cluster (kubeadm)
- Automated cluster bootstrap using Ansible
- Calico CNI networking
- Local Path Provisioner for storage

---

### 🌐 Networking & Access
- NGINX Ingress Controller
- MetalLB for bare-metal LoadBalancer support
- Cloudflare Tunnel + Zero Trust access

---

### 📊 Observability
- Prometheus + Grafana monitoring stack
- Metrics Server for cluster metrics

---

### 🧩 Application Layer
- WordPress deployed on Kubernetes
- MariaDB database with persistent storage
- Ingress-based routing

---

### ⚡ Infrastructure as Code
- Terraform (Proxmox)
- Dynamic VM provisioning via variables
- Cloud-init templates for rapid deployment

---

## 🔁 Resilient Deployment Design (Core Feature)

This platform is designed to **avoid fragile timing assumptions** commonly found in automation.

Instead of relying on fixed waits, it uses:

- Retry-based execution (`retries`, `delay`, `until`)
- Progressive readiness checks (pods exist → stabilise → proceed)
- Idempotent operations (`kubectl apply`, `helm upgrade --install`)
- Recovery-safe Kubernetes bootstrap (`kubeadm reset + retry`)

> The system is designed to **converge to a working state**, even on slow or constrained hardware.

---

## 🏗️ Folder Structure
```
homelab-blog/
├── terraform/    # Proxmox & Cloudflare infrastructure
├── ansible/      # Kubernetes bootstrap & platform deployment
├── kubernetes/   # Manifests (WordPress, Monitoring, MetalLB)
└── scripts/      # Helper scripts (inventory build, local deploy)
```

---

## 🚀 Getting Started

1. **Configure credentials**
   - Copy `.env.example` to `.env` and fill in Proxmox API credentials and SSH key path

2. **Run the pipeline**
   ```bash
   docker-compose up
   ```
   This will automatically:
   - Provision Proxmox VMs via Terraform (outputs IPs to `artifacts/output.json`)
   - Build the Ansible inventory from Terraform output
   - Bootstrap the Kubernetes cluster
   - Install platform services (Ingress, Storage, MetalLB, Monitoring)
   - Deploy WordPress + MariaDB

3. **Configure Cloudflare**
   - Set up Cloudflare Tunnel + Zero Trust manually to expose the cluster ingress

4. Access your blog via:
    [Lennardjohn.org](https://lennardjohn.org/)

---

## 🧪 Lessons Learned

### ❌ What doesn’t work
- Fixed timeouts (`kubectl wait`)
- Sequential scripts with no retries
- Assuming immediate readiness

### ✅ What works
- Eventual consistency
- Retry + backoff strategies
- Layered system design
- Partial readiness checks

---

## 🎯 Why This Project Matters

This project demonstrates:

- Real-world DevOps practices  
- Platform engineering design patterns  
- Distributed system behaviour  
- Resilient automation on constrained infrastructure  

---

## 🔮 Future Improvements

- Multi-cluster deployment (Talos / cloud failover)
- CI/CD pipeline (GitHub Actions)
- Automate Cloudflare Tunnel provisioning via Terraform
- External database management
- Full Cloudflare Zero Trust integration for all services

---

## ⚠️ Known Gotchas (Terraform + Proxmox)

This project includes a curated reference of non-obvious pitfalls:

👉 [`terraform-proxmox-gotchas.md`](terraform/proxmox/terraform-proxmox-gotchas.md)

Topics include:
- Proxmox API token permissions
- Disk cloning and template sizing pitfalls
- Cloud-init quirks
- Terraform provider limitations

---

## 👤 Author

**Lennard John**

- DevOps / Platform Engineering journey  
- Head of Digital Technology (NZ)  
- Building real-world systems on homelab infrastructure  

---

## 💬 Design Insight

This platform was designed to be **resilient rather than deterministic**.

Instead of relying on fixed timing assumptions (e.g. `kubectl wait`), the system uses:
- Retry-based execution
- Progressive readiness checks
- Idempotent operations

This allows the platform to **converge to a working state**, even on slow or resource-constrained infrastructure.

---