# Homelab Blog Platform
![infra](infra.png)

I just wanted to write a blog.

So I built a **production-style platform** from scratch.

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
No manual steps. No SSH required after bootstrap.

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

## Key Engineering Decisions

Git as the source of truth
→ No SSH after bootstrap. All changes flow through Git.
Resilient over deterministic
→ No fixed delays — retry loops and readiness checks ensure convergence.
GitOps for day-2 operations
→ Argo CD continuously reconciles cluster state from Git.
TCP probes instead of HTTP
→ Avoids false failures during WordPress initialisation.
Recreate deployment strategy
→ Prevents PVC deadlocks with ReadWriteOnce volumes.
Zero-trust exposure
→ No open ports — all traffic flows through Cloudflare Tunnel.
DNS-01 TLS challenges
→ Works without direct inbound HTTP access.
Self-hosted CI runner
→ Secure, LAN-accessible, keeps secrets off GitHub.
Persistent Terraform state in CI
→ Prevents resource duplication and Cloudflare conflicts.
NetworkPolicy enforcement
→ Database only accessible by WordPress (defence-in-depth).
Reproducibility
→ This entire platform can be: Destroyed, Rebuilt and Migrated Using the same codebase.



---

## Project Structure

```
homelab-blog/
├── terraform/proxmox/       # VMs, Cloudflare tunnel, DNS records
├── ansible/playbook/        # 9 playbooks: bootstrap through app deploy
├── kubernetes/              # Argo CD syncs this directory
│   ├── wordpress/           # WordPress + MariaDB + NetworkPolicy
│   ├── monitoring/          # Prometheus, Grafana, AlertManager rules
│   ├── argocd/              # Argo CD + Application CRs
│   ├── cloudflared/         # Cloudflare tunnel agent
│   ├── landing/             # Landing page (nginx + ConfigMap)
│   ├── cert-manager/        # ClusterIssuers (prod + staging)
│   └── metallb/             # IP address pool
├── docker/                  # Dockerfiles for terraform + ansible containers
├── scripts/                 # build_inventory.py, sync-env.ps1, teardown.ps1
├── .github/workflows/       # CI/CD pipeline (deploy.yml)
├── docker-compose.yaml      # Orchestrates the full pipeline
└── .env                     # All credentials (git-ignored)
```

---

## Getting Started

**Prerequisites:** Docker, Proxmox host with Ubuntu 24.04 cloud-init template, Cloudflare account with domain, SSH key at `~/.ssh/id_ed25519`

```bash
git clone https://github.com/Lennardj/homelab-blog.git
cd homelab-blog
cp .env.example .env    # fill in all values
docker compose up
```

That's it. ~25 minutes the full platform is live.

---

## Future Improvements

- Multi-cluster deployment (Talos / hybrid cloud)
- Secrets management (SOPS / Vault / OpenBao)
- Progressive delivery (Argo Rollouts)
- Multi-environment (dev / staging / prod)

---

## Known Issues & Incident Log

22 incidents documented and resolved — from Terraform provider quirks to Kubernetes probe failures to CI/CD permission issues.

- [Terraform + Proxmox Gotchas](terraform/proxmox/terraform-proxmox-gotchas.md)
- [Full Incident Log & Forensic Manual](Technical_book/homelab_forensic_manual.md)

---

## Author

**Lennard John** — Platform Engineer

- [YouTube](https://www.youtube.com/@mrjohnhomelab)
- [GitHub](https://github.com/Lennardj)
- [LinkedIn](https://www.linkedin.com/in/lennardjohn/)
- [Dev.to](https://dev.to/lennardj)