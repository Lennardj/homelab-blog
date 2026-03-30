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
    │       └─ Cloudflare: Creates DNS CNAMEs (blog, grafana, argocd, @ root)
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
                 4. deploy-cert-manager.yml  → cert-manager + ClusterIssuer (prod + staging)
                 5. deploy-argocd.yml        → Argo CD via Helm + ingress
                 6. deploy-monitoring.yml    → Helm: Prometheus + Grafana + registers Argo CD app
                 7. deploy-wordpress.yml     → WordPress + MariaDB + secrets + registers Argo CD app
                 8. deploy-cloudflared.yml   → cloudflared pod + tunnel token secret + registers Argo CD app
                 9. deploy-landing.yml       → landing page nginx pod + registers Argo CD app
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

### Remote Access via Tailscale

Tailscale subnet routing allows running the full `docker compose up` pipeline from outside the home network.

**Setup (one-time, on Proxmox host):**
```bash
tailscale up --advertise-routes=192.168.1.0/24 --accept-routes
```
Then approve the route in the Tailscale admin console: Machines → Proxmox → Edit route settings → enable `192.168.1.0/24`.

**On the remote machine running compose:**
```bash
tailscale up --accept-routes
```

**What changes in `.env` for a remote run:**
```bash
TF_VAR_proxmox_api_url=https://<tailscale-ip>:8006/api2/json
# All other values stay the same
```

VM IPs (`192.168.1.70–.72`) and `INGRESS_IP` do not change — they are LAN addresses assigned to the VMs themselves, reachable via the subnet route.

### DNS (Cloudflare-managed)

```
lennardjohn.org         → CNAME @ → <tunnel-id>.cfargotunnel.com (proxied) — landing page
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
        lennardjohn.org         → landing:80      (landing namespace)
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
| `landing` | Personal portfolio landing page (nginx + ConfigMap HTML) |

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
- Deployment strategy: `Recreate` — required because `wordpress-pvc` is ReadWriteOnce; rolling update would deadlock (new pod can't mount PVC held by old pod on different node)
- Liveness: TCP port 80 (60s delay)
- Readiness: TCP port 80 (30s delay) — TCP not HTTP; WordPress returns 500 on fresh install before setup wizard, so httpGet would permanently block the pod from becoming Ready
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
- AlertManager: 2Gi storage, email alerts via Gmail SMTP
- Grafana ingress: `grafana.lennardjohn.org`

**AlertManager — Alert Rules**

| Alert | Condition | Severity |
|---|---|---|
| PodCrashLooping | Pod restarting in last 10 min | critical |
| PodNotReady | Pod not ready for 5 min | warning |
| DeploymentReplicasMismatch | Desired ≠ ready replicas for 10 min | warning |
| NodeNotReady | Node down for 2 min | critical |
| NodeHighMemory | Memory > 85% for 5 min | warning |
| NodeHighCPU | CPU > 85% for 5 min | warning |
| NodeDiskPressure | Disk > 85% for 5 min | warning |

**Notification channels:**
- Email to `lennardvincentjohn@gmail.com` via Gmail SMTP (app password in `.env` as `ALERTMANAGER_SMTP_PASSWORD`, injected by Ansible via `--set`)
- Grafana UI — reads all Prometheus alerts natively, no extra config needed

---

## 8. TLS / cert-manager

### How it works
cert-manager watches for Ingress resources with the `cert-manager.io/cluster-issuer` annotation. When found, it automatically requests a certificate from Let's Encrypt using DNS-01 challenge via the Cloudflare API, stores the cert as a K8s secret, and NGINX ingress serves it.

### ClusterIssuers
Two issuers are deployed:
- `letsencrypt-prod` — production CA, trusted by browsers, **5 duplicate certs per domain per 7 days** rate limit
- `letsencrypt-staging` — staging CA, untrusted by browsers, unlimited — **use this for test runs**

Challenge: DNS-01 via Cloudflare API (both issuers)
Email: `lennardvincentjohn@gmail.com`
Cloudflare API token stored as secret `cloudflare-api-token` in `cert-manager` namespace

**Before recording the video**, switch ingresses from staging to prod:
```bash
sed -i 's/letsencrypt-staging/letsencrypt-prod/g' \
  kubernetes/wordpress/ingress.yaml \
  kubernetes/monitoring/grafana-ingress.yaml \
  kubernetes/argocd/ingress.yaml
```

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
| AlertManager SMTP password | `.env` → `ALERTMANAGER_SMTP_PASSWORD` | Ansible → Helm `--set` |
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
ALERTMANAGER_SMTP_PASSWORD=<gmail-app-password>
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
- **MariaDB OOMKill during init — wordpress database never created**: MariaDB has a 512Mi memory limit. On first boot it can be OOMKilled mid-init (exit code 137). On restart it detects the data dir exists and skips re-initialization, so the `wordpress` database is never created. Fix: `deploy-wordpress.yml` explicitly runs `CREATE DATABASE IF NOT EXISTS wordpress` after MariaDB is ready, independent of its auto-init.
- **Nginx ssl-redirect loop through Cloudflare tunnel**: With `ssl-redirect: true`, nginx redirects HTTP→HTTPS. Cloudflare tunnel sends HTTP internally to nginx, causing an infinite redirect loop on all non-local devices. Fix: `ssl-redirect: false` on all ingresses — Cloudflare enforces HTTPS at its edge, nginx does not need to.
- **Stale MariaDB PVC / Host not allowed**: If Ansible runs against existing VMs without a full teardown, the MariaDB PVC retains old data. MariaDB skips re-initialization and keeps old user grants — wordpress user may have a restricted host that doesn't match the new pod IP. Fix: `deploy-wordpress.yml` explicitly runs `GRANT ALL PRIVILEGES ON wordpress.* TO 'wordpress'@'%'` after MariaDB starts, ensuring correct host grants on every deploy regardless of PVC state. Security note: `%` is safe here because MariaDB is a ClusterIP service with no external exposure.
- **GRANT fails with socket error**: The wait task checked pod `Running` state, but MariaDB initialization takes additional time after the container starts. The socket `/run/mysqld/mysqld.sock` doesn't exist until MariaDB finishes init. Fix: replaced the Running check with a `SELECT 1` connection check — retries until MariaDB actually accepts connections before running GRANT.
- **MariaDB 11.8 unix_socket auth**: MariaDB 11.8 uses `unix_socket` plugin for root by default — `mariadb -uroot -p"..."` fails with `Access denied`. Root can only authenticate passwordlessly via the container's OS user (i.e. `kubectl exec`). Fix: removed `-p` flag from both the `SELECT 1` check and the `GRANT` task. This is more secure than password auth — root access is restricted to container-local `kubectl exec` only.

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
- Landing: https://lennardjohn.org
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

### Before Recording the Video (one-time swap)
```bash
sed -i 's/letsencrypt-staging/letsencrypt-prod/g' \
  kubernetes/wordpress/ingress.yaml \
  kubernetes/monitoring/grafana-ingress.yaml \
  kubernetes/argocd/ingress.yaml
git add -p && git commit -m "Switch to prod TLS for video" && git push
```
Wait ~60s after deploy for trusted certs to issue, then record.

### Pre-flight

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

---

## 15. CI/CD — GitHub Actions (Self-Hosted Runner)

### Architecture

```
git push (terraform/ or ansible/ change)
  → GitHub detects path match
  → Sends job to runner-01 (self-hosted VM on Proxmox)
  → runner-01 runs docker compose up
      → terraform container → provisions VMs
      → ansible container  → deploys K8s
  → Cleanup: docker compose down --volumes
```

`kubernetes/` changes do NOT trigger this workflow — Argo CD handles those via GitOps.

### Runner VM

| Property | Value |
|---|---|
| Name | runner-01 |
| IP | 192.168.1.73 |
| Hosted on | Proxmox (permanent VM, not Terraform-managed) |
| Labels | `self-hosted`, `Linux`, `X64` |
| Work dir | `~/actions-runner/_work/` |
| Service | systemd (`sudo ./svc.sh install && start`) |

The runner replaces the developer's laptop as the machine that runs `docker compose up`. All secrets stay on the runner VM — GitHub never sees them.

### Secrets on the Runner VM

| File | Location | Purpose |
|---|---|---|
| `.env` | `/home/lennard/.env` | All pipeline credentials |
| SSH private key | `~/.ssh/id_ed25519` | Ansible SSH auth to K8s nodes |

**Key difference from laptop:** `SSH_KEY_DIR=/home/lennard/.ssh` (Linux path, not Windows).

**Syncing `.env` from laptop to runner VM:**
```powershell
.\scripts\sync-env.ps1
```

### Workflow File

`.github/workflows/deploy.yml` — triggers on push to `main` when `terraform/**` or `ansible/**` paths change.

```yaml
- Checkout repo into _work/
- Copy /home/runner/.env → .env
- docker compose up
- docker compose down --volumes --remove-orphans  (always, even on failure)
```

`concurrency: group: deploy` — prevents two deploys running at the same time if pushes happen in quick succession.

### Why Self-Hosted (not GitHub-hosted)

GitHub-hosted runners are cloud VMs with no LAN access. They cannot reach Proxmox (`192.168.1.174`) or the K8s nodes (`192.168.1.70-72`) without a Tailscale tunnel. A self-hosted runner on Proxmox has direct LAN access and keeps all secrets off GitHub.

---

## 16. Next Steps: Secrets Management

### Current State

All secrets live in `.env` on the local machine. Docker Compose injects them as env vars into Terraform and Ansible containers. Nothing sensitive is committed to Git.

**Limitation:** `.env` is manual, per-machine, and not auditable. If a CI pipeline (GitHub Actions) needs to run the Ansible playbooks, there is no safe way to inject `.env` into it without hardcoding secrets in YAML.

### Options

| Option | Notes |
|--------|-------|
| **HashiCorp Vault** | The original. Kubernetes Helm deployment, raft storage (no external DB). Most features, steepest learning curve. BSL license since 2023. |
| **OpenBao** | Community fork of Vault after the BSL change. Drop-in replacement, MPL-2.0 license. Best choice if you want Vault but fully open source. |
| **Infisical** | Modern UI, easier setup, built-in K8s operator. Good docs. Slightly less mature than Vault. |
| **Doppler** | SaaS-first, self-hosted option is enterprise only. Not worth it for homelab. |
| **SOPS + age** | Not a server — encrypts secrets files with a key pair. Simpler: no new service to run. Works with Argo CD via the SOPS plugin. |

### Recommended Path for This Project

1. **Short term — SOPS + age**: Encrypt `.env` (or individual secret files), commit the encrypted file to Git. Argo CD decrypts on apply using a key stored in-cluster. CI pipelines get the same key from a GitHub Actions secret. Zero new infrastructure.
2. **Long term — OpenBao in-cluster + External Secrets Operator**: Full secrets management with audit logs, access policies, and dynamic secrets. External Secrets Operator syncs Vault secrets into K8s secrets automatically.

### How Vault fits the GitOps pipeline

```
Current:  .env (local) → Docker Compose → Ansible → K8s secrets
With Vault: Vault (in-cluster) → External Secrets Operator → K8s secrets
            .env only needed to bootstrap Vault once
```

Argo CD + External Secrets Operator means secrets are never in Git, never in `.env` on CI, and are rotatable without redeploying the application.
