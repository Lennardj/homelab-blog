# Homelab Blog — Knowledge Base

## 1. Project Overview

A production-style, self-hosted blog platform demonstrating DevOps and Platform Engineering on homelab infrastructure. Fully automated from VM provisioning through application deployment using Terraform, Ansible, and Kubernetes.

**Author:** Lennard John
**Domain:** lennardjohn.org
**Repo:** https://github.com/Lennardj/homelab-blog

---

## 2. Directory Structure

```
homelab-blog/
├── terraform/proxmox/
│   ├── main.tf                  # VM provisioning (control plane + workers)
│   ├── variables.tf             # All input variables
│   ├── provider.tf              # Proxmox + Cloudflare providers
│   ├── outputs.tf               # VM IPs, hostnames, tunnel token
│   ├── cloudflare.tf            # Cloudflare tunnel + DNS records
│   └── terraform.tfvars         # Credentials (git-ignored)
│
├── ansible/playbook/
│   ├── playbook.yml             # K8s prerequisites + cluster init (kubeadm)
│   ├── cluster-services.yml     # NGINX ingress, Local Path Provisioner, Metrics Server
│   ├── cluster-networking.yml   # MetalLB install + ingress LoadBalancer patch
│   ├── deploy-cert-manager.yml  # cert-manager via Helm + ClusterIssuer
│   ├── deploy-argocd.yml        # Argo CD via Helm + ingress
│   ├── deploy-monitoring.yml    # Prometheus + Grafana via Helm
│   ├── deploy-wordpress.yml     # WordPress + MariaDB
│   └── deploy-cloudflared.yml   # Cloudflare tunnel deployment
│
├── kubernetes/
│   ├── wordpress/               # Namespace, PVCs, MariaDB, WordPress, Ingress, kustomization.yaml
│   ├── cloudflared/             # Namespace, Deployment, kustomization.yaml
│   ├── monitoring/              # Namespace, Helm values, Grafana ingress, kustomization.yaml
│   ├── argocd/                  # Namespace, Helm values, Ingress, apps/ (Application CRs)
│   └── metallb/                 # IPAddressPool + L2Advertisement
│
├── docker/
│   ├── terraform/Dockerfile     # hashicorp/terraform:1.14 + bash, curl, jq, netcat-openbsd
│   ├── terraform/run.sh         # terraform init → apply → SSH poll → output.json
│   ├── ansible/Dockerfile       # python:3.12.0-slim + ansible==13.5.0
│   └── ansible/wait.sh          # (commented out, unused)
│
├── scripts/
│   └── build_inventory.py       # Reads output.json → builds Ansible inventory → runs playbooks
│
├── artifacts/
│   └── output.json              # Written by Terraform, read by Ansible (git-ignored)
│
├── docker-compose.yaml          # Orchestrates terraform → ansible pipeline
└── .env                         # All credentials and config (git-ignored)
```

---

## 3. Technology Stack

| Component | Version | Purpose |
|---|---|---|
| Terraform | 1.14 | Infrastructure provisioning |
| Proxmox Provider | 3.0.2-rc07 | VM management |
| Cloudflare Provider | >= 5.0 | DNS + Zero Trust tunnel |
| Ubuntu | 24.04 LTS | VM OS (cloud-init template) |
| Kubernetes | v1.30 | Container orchestration |
| Calico CNI | v3.27.0 | Pod networking |
| NGINX Ingress | v1.10.1 | Ingress controller |
| MetalLB | v0.14.5 | LoadBalancer IP assignment |
| Local Path Provisioner | v0.0.35 | Persistent storage |
| Metrics Server | v0.8.1 | Kubelet metrics |
| kube-prometheus-stack | Latest (Helm) | Prometheus + Grafana + AlertManager |
| WordPress | php8.2-apache | Blog application |
| MariaDB | 11 | Database |
| cloudflared | latest | Cloudflare tunnel agent |
| Argo CD | Latest (Helm) | GitOps continuous reconciliation |
| Ansible | 13.5.0 | Configuration management |
| Python | 3.12.0 | Scripting (build_inventory.py) |

---

## 4. Full Deployment Pipeline

```
docker-compose up
    │
    ├── [terraform container]
    │     terraform init
    │     terraform apply -auto-approve
    │       ├─ Proxmox: Creates k8s-master-01 (VM 150)
    │       ├─ Proxmox: Creates k8s-worker-1 (VM 200)
    │       ├─ Proxmox: Creates k8s-worker-2 (VM 201)
    │       ├─ Cloudflare: Creates Zero Trust tunnel
    │       └─ Cloudflare: Creates DNS CNAMEs (blog, grafana)
    │     SSH poll each VM until port 22 responds
    │     terraform output -json > /artifacts/output.json
    │
    └── [ansible container]
          build_inventory.py
            ├─ Polls /artifacts/output.json until written
            ├─ Builds /work/ansible/inventory/hosts.ini
            └─ Runs playbooks in order:
                 1. playbook.yml             → K8s prerequisites + kubeadm init + calico
                 2. cluster-services.yml     → NGINX ingress + storage + metrics server
                 3. cluster-networking.yml   → MetalLB + patch ingress to LoadBalancer
                 4. deploy-cert-manager.yml  → cert-manager + ClusterIssuer
                 5. deploy-argocd.yml        → Argo CD via Helm + ingress
                 6. deploy-monitoring.yml    → Helm: Prometheus + Grafana + registers Argo CD app
                 7. deploy-wordpress.yml     → WordPress + MariaDB + secrets + registers Argo CD app
                 8. deploy-cloudflared.yml   → cloudflared pod + tunnel token secret + registers Argo CD app
```

**Total deployment time:** ~20-30 minutes

---

## 5. Infrastructure: VMs

| VM | ID | Role | CPU | RAM | Disk |
|---|---|---|---|---|---|
| k8s-master-01 | 150 | Control plane | 2 cores, 2 sockets | 4096 MB | 70 GB |
| k8s-worker-1 | 200 | Worker | 2 cores, 2 sockets | 2048 MB | 70 GB |
| k8s-worker-2 | 201 | Worker | 2 cores, 2 sockets | 2048 MB | 70 GB |

- OS user: `lennard`
- Auth: SSH key + cloud-init password
- Network: Static IPs via cloud-init (`ipconfig0`), DNS: `8.8.8.8 8.8.4.4`
- `ciupgrade = false` — cloud-init upgrade disabled to prevent apt lock conflicts on boot
- Clone template: `ubuntu-cloud` (Ubuntu 24.04 with qemu-guest-agent)

---

## 6. Networking

### IP Addressing

```
Proxmox host:       192.168.1.174:8006
k8s-master-01:      192.168.1.70  (static, cloud-init)
k8s-worker-1:       192.168.1.71  (static, cloud-init)
k8s-worker-2:       192.168.1.72  (static, cloud-init)
Pod CIDR:           10.96.0.0/16 (Calico)
MetalLB pool:       192.168.1.80 – 192.168.1.90
Ingress IP:         192.168.1.80 (first IP in MetalLB pool)
Gateway:            192.168.1.254
```

### DNS (Cloudflare-managed)

```
blog.lennardjohn.org    → CNAME → <tunnel-id>.cfargotunnel.com (proxied)
grafana.lennardjohn.org → CNAME → <tunnel-id>.cfargotunnel.com (proxied)
argocd.lennardjohn.org  → CNAME → <tunnel-id>.cfargotunnel.com (proxied)
```

### Traffic Flow

```
Browser → Cloudflare DNS → Cloudflare Edge
    → Cloudflare Tunnel → cloudflared pod (cloudflared namespace)
    → ingress-nginx-controller.ingress-nginx.svc.cluster.local
    → NGINX Ingress rules:
        blog.lennardjohn.org    → wordpress:80    (wordpress namespace)
        grafana.lennardjohn.org → grafana:80      (monitoring namespace)
        argocd.lennardjohn.org  → argocd-server:80 (argocd namespace)
```

---

## 7. Kubernetes Workloads

### Namespaces

| Namespace | Contents |
|---|---|
| `kube-system` | kubelet, calico, coredns, metrics-server |
| `ingress-nginx` | NGINX ingress controller (LoadBalancer: 192.168.1.80) |
| `metallb-system` | MetalLB controller + speaker |
| `local-path-storage` | Local path provisioner |
| `cert-manager` | cert-manager + webhook + cainjector, ClusterIssuer |
| `argocd` | Argo CD server, repo-server, application-controller, dex, redis |
| `monitoring` | Prometheus, Grafana, AlertManager |
| `wordpress` | WordPress, MariaDB, PVCs, Ingress |
| `cloudflared` | cloudflared tunnel agent |

### wordpress namespace

**MariaDB**
- Image: `mariadb:11`
- Resources: 100m/500m CPU, 256Mi/512Mi memory
- PVC: 8Gi (local-path)
- Probes: TCP 3306 (liveness 60s delay, readiness 30s delay)
- Env from secret: `wordpress-secrets`

**WordPress**
- Image: `wordpress:php8.2-apache`
- Resources: 100m/500m CPU, 128Mi/512Mi memory
- PVC: 8Gi (local-path)
- Liveness: TCP port 80 (60s delay) — TCP avoids DB-dependent HTTP checks killing the pod on fresh deploy
- Readiness: HTTP GET / port 80 (30s delay, 5s timeout) — follows 302 to install page on fresh deploy
- DB host: `mariadb:3306`
- Ingress: `blog.lennardjohn.org`

**Secret: wordpress-secrets** (created by Ansible, not committed)
- `mariadb-root-password` ← `MARIADB_ROOT_PASSWORD` (.env)
- `mariadb-password` ← `MARIADB_PASSWORD` (.env)
- `mariadb-database`: wordpress
- `mariadb-user`: wordpress

### cloudflared namespace

**cloudflared**
- Image: `cloudflare/cloudflared:2024.10.0`
- Replicas: 2
- Resources: 50m/200m CPU, 64Mi/128Mi memory
- Probes: HTTP GET /ready port 2000 — requires `--metrics 0.0.0.0:2000` flag, otherwise metrics binds to 127.0.0.1 on a random port and probe fails
- Auth: token-based (`--token $(TUNNEL_TOKEN)`)
- Token from secret: `cloudflared-token` ← fetched from Cloudflare API by Ansible
- Ingress rules managed via Cloudflare API (Terraform `terraform_data` resource) — no local ConfigMap

### monitoring namespace

**kube-prometheus-stack (Helm)**
- Prometheus: 5Gi storage
- Grafana: 2Gi storage, admin password from `GRAFANA_ADMIN_PASSWORD` (.env)
- AlertManager: 2Gi storage
- Grafana ingress: `grafana.lennardjohn.org`

---

## 8. TLS / cert-manager

### How it works
cert-manager watches for Ingress resources with the `cert-manager.io/cluster-issuer` annotation. When found, it automatically requests a certificate from Let's Encrypt using DNS-01 challenge via the Cloudflare API, stores the cert as a K8s secret, and NGINX ingress serves it.

### ClusterIssuer
- Issuer: `letsencrypt-prod` (Let's Encrypt production)
- Challenge: DNS-01 via Cloudflare API
- Email: `lennardvincentjohn@gmail.com` (expiry notifications)
- Cloudflare API token stored as secret `cloudflare-api-token` in `cert-manager` namespace

### Certificates
| Domain | Secret | Namespace |
|---|---|---|
| `blog.lennardjohn.org` | `wordpress-tls` | `wordpress` |
| `grafana.lennardjohn.org` | `grafana-tls` | `monitoring` |
| `argocd.lennardjohn.org` | `argocd-tls` | `argocd` |

### Why DNS-01 (not HTTP-01)
The Cloudflare tunnel means there is no direct HTTP path from the internet to the cluster. Let's Encrypt's HTTP-01 challenge requires hitting `/.well-known/acme-challenge/` on the domain — this would fail because the tunnel doesn't expose that path reliably. DNS-01 proves domain ownership by creating a TXT record via the Cloudflare API instead — no inbound HTTP needed.

### Playbook order
cert-manager must be installed BEFORE wordpress and monitoring ingresses are applied, so certificates are provisioned at deploy time.

---

## 9. Cloudflare Setup

### What Terraform Creates
- `cloudflare_zero_trust_tunnel_cloudflared` → tunnel named `homelab-k8s`
- `cloudflare_dns_record` → `blog` CNAME
- `cloudflare_dns_record` → `grafana` CNAME
- `cloudflare_dns_record` → `argocd` CNAME
- `terraform_data.tunnel_config` → configures ingress rules via Cloudflare API (`PUT /cfd_tunnel/{id}/configurations`)

### Tunnel Token Flow
```
Terraform creates tunnel → outputs tunnel_id + account_id → written to /artifacts/output.json
  → Ansible reads output.json
  → Ansible fetches tunnel token via Cloudflare API (GET /cfd_tunnel/{id}/token)
  → Creates cloudflared-token K8s secret
  → cloudflared pod reads token → authenticates with Cloudflare edge
```

### Ingress Rules (Cloudflare API — not local ConfigMap)
Managed by `terraform_data.tunnel_config` in `cloudflare.tf` via PUT to Cloudflare API. Routes:
- `blog.lennardjohn.org` → `http://ingress-nginx-controller.ingress-nginx.svc.cluster.local`
- `grafana.lennardjohn.org` → `http://ingress-nginx-controller.ingress-nginx.svc.cluster.local`
- `argocd.lennardjohn.org` → `http://ingress-nginx-controller.ingress-nginx.svc.cluster.local`
- Default → `http_status:404`

**Why not a local ConfigMap:** Cloudflare provider v5 removed `cloudflare_zero_trust_tunnel_cloudflared_config`. Token auth fetches config from the Cloudflare API — a local config file is ignored. Adding a new subdomain = update `cloudflare.tf` and re-apply.

---

## 9. Secrets Management

| Secret | Where Stored | How Injected |
|---|---|---|
| Proxmox API token | `.env` → `TF_VAR_*` | Terraform reads env var |
| Cloudflare API token | `.env` → `TF_VAR_*` | Terraform reads env var |
| Cloud-init VM password | `.env` → `TF_VAR_cloudinit_password` | Terraform cloud-init |
| MariaDB root password | `.env` → `MARIADB_ROOT_PASSWORD` | Ansible → K8s secret |
| MariaDB app password | `.env` → `MARIADB_PASSWORD` | Ansible → K8s secret |
| Grafana admin password | `.env` → `GRAFANA_ADMIN_PASSWORD` | Ansible → Helm `--set` |
| Cloudflare tunnel token | Terraform output → `output.json` | Ansible → K8s secret |

All secrets are git-ignored. Nothing sensitive is committed to the repo.

---

## 10. Environment Variables (.env)

```bash
# SSH
SSH_KEY_DIR=C:/Users/User/.ssh

# Proxmox
TF_VAR_proxmox_api_url=https://192.168.1.174:8006/api2/json
TF_VAR_proxmox_api_token_id=lennard@pam!terraform-token
TF_VAR_proxmox_api_token_secret=<uuid>

# Cloudflare
TF_VAR_cloudflare_api_token=<token>
TF_VAR_cloudflare_zone_id=<zone-id>
TF_VAR_cloudflare_account_id=<account-id>
TF_VAR_domain_name=lennardjohn.org

# Passwords (change before deploying)
MARIADB_ROOT_PASSWORD=change-me-root
MARIADB_PASSWORD=change-me-app
GRAFANA_ADMIN_PASSWORD=change-me-grafana
TF_VAR_cloudinit_password=change-me-vms

# Networking
INGRESS_IP=192.168.1.70
```

---

## 11. Known Issues & Quirks

### Proxmox + Terraform
- **Disk sizing:** Template disk must be ≤ VM disk size — if template > VM, Proxmox detaches it as `unused0` and the VM boots blank
- **IP discovery:** Requires `qemu-guest-agent` installed in the template. IPs only appear in Terraform output once the guest agent reports them
- **Static IPs via cloud-init:** VMs use `ipconfig0 = "ip=X.X.X.X/24,gw=Y.Y.Y.Y"` — prevents DHCP from assigning IPs that conflict with MetalLB pool
- **Provider version:** Using `3.0.2-rc07` (release candidate) — may have bugs
- **TLS insecure:** `pm_tls_insecure = true` by default (self-signed cert on Proxmox)

### WordPress
- **HTTP 500 on liveness probe**: WordPress returns 500 if it can't connect to DB on first startup. Liveness probe kills the pod before it stabilises. Fix: use TCP liveness probe so Apache uptime is checked independently of DB state.
- **Readiness probe timeout**: Probe path `/` redirects to `/wp-admin/install.php` on a fresh deploy. Install page takes >1s to load → `context deadline exceeded`. Fix: `timeoutSeconds: 5`.
- **Install wizard on every request**: Expected on first deploy — WordPress tables don't exist yet. Complete setup at `blog.lennardjohn.org/wp-admin/install.php` after deployment.
- **Stale MariaDB PVC / Host not allowed**: If Ansible runs against existing VMs without a full teardown, the MariaDB PVC retains old data. MariaDB skips re-initialization and keeps old user grants — wordpress user may have a restricted host that doesn't match the new pod IP. Fix: `deploy-wordpress.yml` explicitly runs `GRANT ALL PRIVILEGES ON wordpress.* TO 'wordpress'@'%'` after MariaDB starts, ensuring correct host grants on every deploy regardless of PVC state. Security note: `%` is safe here because MariaDB is a ClusterIP service with no external exposure.
- **GRANT fails with socket error**: The wait task checked pod `Running` state, but MariaDB initialization takes additional time after the container starts. The socket `/run/mysqld/mysqld.sock` doesn't exist until MariaDB finishes init. Fix: replaced the Running check with a `SELECT 1` connection check — retries until MariaDB actually accepts connections before running GRANT.

### cloudflared
- **CrashLoopBackOff, metrics unreachable**: Metrics server binds to `127.0.0.1` on a random port by default. Liveness probe on port 2000 fails. Fix: pass `--metrics 0.0.0.0:2000` in container args.
- **Rollout timeout on slow hardware**: Image pull can take 2+ minutes on old hardware. Ansible's `kubectl rollout status --timeout=120s` was too short. Increased to `600s` — pods were actually healthy, just slow to pull.

### Ansible Bootstrap
- **Helm** is installed in `cluster-services.yml` (playbook #2) so it is available to all subsequent playbooks (`deploy-cert-manager.yml`, `deploy-monitoring.yml`, etc.). Uses `creates: /usr/local/bin/helm` for idempotency.
- `unattended-upgrades`, `apt-daily.timer`, and `apt-daily-upgrade.timer` are all stopped and disabled before any `apt` task runs. Stopping the service alone is not enough — the timers restart it. All three must be disabled to keep apt clear for the full playbook run.
- `dpkg --configure -a` runs after stopping the service to clean any partial package state it left behind.
- `ciupgrade = false` in Terraform prevents cloud-init from running `apt-get upgrade` on boot — this was the original source of the apt lock conflict.
- Static IPs require an explicit `nameserver` in Terraform (`nameserver = "8.8.8.8 8.8.4.4"`) — without it, VMs have no DNS and `apt-get update` fails silently with a blank error message.
- On old/slow hardware, increase SSH wait `delay` to 60s and apt lock wait to `retries: 30, delay: 30` to give nodes enough time.
- `kubeadm init` can fail if containerd socket isn't ready — retry loop handles this
- MetalLB IP assignment takes a few seconds after install — ingress patch retries 20x

### Docker Compose
- `depends_on` only controls start order, not completion. Ansible starts immediately after Terraform container starts. `build_inventory.py` polls `output.json` (up to 20 min) to wait for Terraform to finish
- Terraform output uses `.tmp` → rename pattern for atomic writes

### Cloudflare
- `cloudflare_zero_trust_tunnel_cloudflared_config` does not exist in provider v5 — ingress rules are managed via `terraform_data` + Cloudflare API instead
- `domain_name` Terraform variable is currently unused (DNS records hardcoded, ingress rules in API call) but left in variables.tf for future use
- `tunnel_token` is not a Terraform output attribute in v5 — fetched separately by Ansible via `GET /accounts/{id}/cfd_tunnel/{id}/token`

---

## 12. How to Deploy

### Prerequisites
- Docker Desktop with WSL2
- SSH key at `~/.ssh/id_ed25519`
- Proxmox host with Ubuntu 24.04 cloud-init template + qemu-guest-agent
- Cloudflare account with domain, Zone ID, Account ID, and API token

### Steps

```bash
# 1. Clone repo
git clone https://github.com/Lennardj/homelab-blog.git
cd homelab-blog

# 2. Create .env with real credentials (see section 10)
# Replace all change-me-* values with real passwords

# 3. Run full pipeline
docker-compose up

# 4. Monitor progress
docker-compose logs -f terraform
docker-compose logs -f ansible

# 5. Verify (after ~20-30 min)
ssh lennard@192.168.1.171
kubectl get nodes
kubectl get pods -A
```

### Access
- Blog: https://blog.lennardjohn.org
- Grafana: https://grafana.lennardjohn.org (admin / GRAFANA_ADMIN_PASSWORD)
- Argo CD: https://argocd.lennardjohn.org (admin / retrieve with `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`)

### Teardown
Run from repo root in PowerShell:
```powershell
.\scripts\teardown.ps1
```
This will:
1. `terraform destroy` (via Docker container)
2. `docker compose down --volumes`
3. `docker system prune --all --force --volumes`
4. Delete `.terraform/`, `.terraform.lock.hcl`, `terraform.tfstate*`
5. Clear `artifacts/output.json` and `ansible/inventory/hosts.ini`

---

## 13. Argo CD (GitOps) ✅ Implemented

### Why
Converts day-2 operations from push-based (Ansible `kubectl apply`) to pull-based GitOps. Argo CD watches the `kubernetes/` directory in the GitHub repo and automatically reconciles the cluster to match. Changing a workload = `git push`, no Ansible re-run needed.

### Architecture
```
git push (kubernetes/ change)
  → Argo CD detects diff → kubectl apply -k → cluster reconciles

Ansible (bootstrap only, runs once):
  → installs Argo CD → creates secrets → registers Application CRs
```

### Files
```
kubernetes/argocd/
  namespace.yaml             # argocd namespace
  values.yaml                # Helm values: server.insecure=true (NGINX handles TLS)
  ingress.yaml               # Ingress for argocd.lennardjohn.org
  apps/
    wordpress.yaml           # Application CR → kubernetes/wordpress
    monitoring.yaml          # Application CR → kubernetes/monitoring
    cloudflared.yaml         # Application CR → kubernetes/cloudflared

ansible/playbook/
  deploy-argocd.yml          # Installs Argo CD via Helm, waits for rollout, applies ingress
```

### Application CR registration timing
Each Application CR is applied at the END of its respective playbook — after secrets are created:
- `deploy-monitoring.yml` → applies `apps/monitoring.yaml`
- `deploy-wordpress.yml` → applies `apps/wordpress.yaml`
- `deploy-cloudflared.yml` → applies `apps/cloudflared.yaml`

This prevents Argo CD from syncing before secrets exist (which would cause pod crashloops).

### kustomization.yaml alignment
All three app directories have a `kustomization.yaml` listing only K8s manifests:
- `kubernetes/wordpress/kustomization.yaml` — excludes `secrets.yaml` (Ansible creates with real values)
- `kubernetes/monitoring/kustomization.yaml` — excludes `values.yaml` (Helm values, not a K8s resource)
- `kubernetes/cloudflared/kustomization.yaml` — excludes tunnel token secret (Ansible creates it)

Both Ansible (`kubectl apply -k`) and Argo CD use kustomize, so they apply exactly the same resources.

### Secrets that stay in Ansible (never in Git)
| Secret | Created by |
|--------|-----------|
| `wordpress-secrets` | `deploy-wordpress.yml` |
| `cloudflared-token` | `deploy-cloudflared.yml` |
| `cloudflare-api-token` | `deploy-cert-manager.yml` |
| `argocd-tls` | cert-manager (auto, from Ingress annotation) |

### Sync policy
All apps: `automated` with `prune: true` and `selfHeal: true`
- `prune`: removes resources deleted from Git
- `selfHeal`: reverts manual `kubectl` changes that drift from Git

---

## 14. Deployment Checklist

- [ ] Proxmox API accessible at `192.168.1.174:8006`
- [ ] Cloud-init template `ubuntu-cloud` exists in Proxmox
- [ ] Proxmox API token has full ACLs
- [ ] Cloudflare domain, Zone ID, Account ID ready
- [ ] Cloudflare API token created (Zero Trust + DNS edit)
- [ ] SSH key at `~/.ssh/id_ed25519`
- [ ] `.env` filled with real values (no `change-me-*` remaining)
- [ ] `docker-compose up` running
- [ ] `artifacts/output.json` written
- [ ] `kubectl get nodes` shows 3 Ready nodes
- [ ] `blog.lennardjohn.org` loads WordPress
- [ ] `grafana.lennardjohn.org` loads Grafana
- [ ] `argocd.lennardjohn.org` loads Argo CD UI
- [ ] All 3 Argo CD apps show `Synced` + `Healthy`
