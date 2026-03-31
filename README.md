# Homelab Blog Platform
![iinfra]("./infra.png")
This is **not a blog project**.

It's a **self-hosted Platform-as-a-Service (PaaS)** that:
- Provisions infrastructure
- Bootstraps Kubernetes
- Deploys applications
- Manages everything through Git

All from a single command:

```bash
docker compose up
```

**Live:** [lennardjohn.org](https://lennardjohn.org) | [blog](https://blog.lennardjohn.org) | [grafana](https://grafana.lennardjohn.org) | [argocd](https://argocd.lennardjohn.org)

---

## Full Deployment Pipeline

```text
docker compose up
    │
    ├── Terraform
    │     → Proxmox: creates 3 VMs (1 master + 2 workers)
    │     → Cloudflare: tunnel + DNS records (blog, grafana, argocd, landing)
    │
    └── Ansible (9 playbooks, in order)
          → K8s bootstrap (kubeadm + Calico CNI)
          → Platform services (NGINX Ingress, MetalLB, Local Path, Metrics Server)
          → cert-manager + Let's Encrypt (automated TLS)
          → Argo CD (GitOps)
          → Prometheus + Grafana + AlertManager (monitoring + email alerts)
          → WordPress + MariaDB (the blog)
          → Cloudflare Tunnel agent
          → Landing page (lennardjohn.org)

After deployment:
    kubernetes/ change → Argo CD auto-syncs (no CI needed)
    terraform/ or ansible/ change → GitHub Actions → self-hosted runner → full rebuild
```

---

## Stack

| Layer | Tools |
|---|---|
| Hypervisor | Proxmox VE (3 VMs: 1 master + 2 workers) |
| Provisioning | Terraform (Proxmox + Cloudflare providers) |
| Configuration | Ansible (9 sequential playbooks) |
| Orchestration | Kubernetes v1.30 (kubeadm) |
| Networking | Calico CNI, MetalLB, NGINX Ingress |
| Storage | Local Path Provisioner |
| TLS | cert-manager + Let's Encrypt (DNS-01 via Cloudflare) |
| Applications | WordPress + MariaDB, Landing Page |
| Monitoring | Prometheus, Grafana, AlertManager (7 rules, email alerts) |
| GitOps | Argo CD (auto-syncs `kubernetes/` on every push) |
| Access | Cloudflare Tunnel (zero-trust, no port forwarding) |
| CI/CD | GitHub Actions (self-hosted runner on Proxmox) |
| Security | NetworkPolicy (MariaDB restricted to WordPress only) |

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