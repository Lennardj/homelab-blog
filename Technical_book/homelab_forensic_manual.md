# Homelab Project Forensic Manual & Interview Study Guide

**Author:** Lennard John
**Project:** Automated WordPress + Monitoring deployment on Proxmox
**Status:** In progress — incidents documented as encountered.

---

## How Everything Connects: The Full Dependency Map

This section is a complete map of every tool, config file, credential, and Kubernetes resource — showing exactly how they chain together. The goal is to be able to explain the full pipeline from memory in an interview.

---

### 1. Tool → Tool Dependencies

```
.env (source of all credentials and config)
  │
  ├─► docker-compose.yaml (env_file: .env)
  │     │
  │     ├─► [terraform container]
  │     │     docker/terraform/Dockerfile (FROM hashicorp/terraform:1.14)
  │     │     docker/terraform/run.sh
  │     │       → terraform init
  │     │       → terraform apply -auto-approve
  │     │           → Proxmox API: creates 3 VMs
  │     │           → Cloudflare API: creates tunnel + DNS records + ingress rules
  │     │       → polls SSH on each VM IP
  │     │       → terraform output -json > /artifacts/output.json
  │     │
  │     └─► [ansible container] (depends_on: terraform)
  │           docker/ansible/Dockerfile (FROM python:3.12.0-slim + ansible==13.5.0)
  │           scripts/build_inventory.py
  │             → reads /artifacts/output.json
  │             → writes ansible/inventory/hosts.ini
  │             → copies SSH key: /keys/id_ed25519 → /root/.ssh/id_ed25519
  │             → runs 8 playbooks in sequence:
  │                 1. ansible/playbook/playbook.yml
  │                 2. ansible/playbook/cluster-services.yml
  │                 3. ansible/playbook/cluster-networking.yml
  │                 4. ansible/playbook/deploy-cert-manager.yml
  │                 5. ansible/playbook/deploy-argocd.yml
  │                 6. ansible/playbook/deploy-monitoring.yml
  │                 7. ansible/playbook/deploy-wordpress.yml
  │                 8. ansible/playbook/deploy-cloudflared.yml
  │
  └─► Argo CD (running in cluster, continuous)
        watches: https://github.com/Lennardj/homelab-blog (main branch)
        polls: kubernetes/wordpress/, kubernetes/monitoring/, kubernetes/cloudflared/
        on diff: kubectl apply -k <path>
```

---

### 2. File → File Dependencies

Every file that reads from or writes to another file:

| File (writer) | Produces | File (reader) | How it reads |
|---|---|---|---|
| `docker/terraform/run.sh` | `/artifacts/output.json` | `scripts/build_inventory.py` | `json.loads(path.read_text())` line 21 |
| `scripts/build_inventory.py` | `ansible/inventory/hosts.ini` | all `ansible-playbook` commands | `-i /work/ansible/inventory/hosts.ini` |
| `terraform/proxmox/outputs.tf` | `output.cloudflare_tunnel_id` | `deploy-cloudflared.yml` | `terraform_output.cloudflare_tunnel_id.value` |
| `terraform/proxmox/outputs.tf` | `output.cloudflare_account_id` | `deploy-cloudflared.yml` | `terraform_output.cloudflare_account_id.value` |
| `terraform/proxmox/outputs.tf` | `output.all_nodes_ips` | `build_inventory.py` | `data["all_nodes_ips"]["value"]` line 39 |
| `terraform/proxmox/outputs.tf` | `output.all_nodes_hostnames` | `build_inventory.py` | `data["all_nodes_hostnames"]["value"]` line 38 |
| `terraform/proxmox/outputs.tf` | `output.control_plane_ip` | `build_inventory.py` | `data["control_plane_ip"]["value"]` line 60 |
| `terraform/proxmox/outputs.tf` | `output.worker_ips` | `build_inventory.py` | `data["worker_ips"]["value"]` line 61 |
| `kubernetes/*/kustomization.yaml` | resource list | `kubectl apply -k` | Ansible + Argo CD both use `-k` |
| `kubernetes/argocd/apps/*.yaml` | `repoURL`, `path` | Argo CD Application controller | Argo CD reads CRs from the cluster |
| `kubernetes/monitoring/values.yaml` | Helm values | `deploy-monitoring.yml` | `--values /tmp/monitoring/values.yaml` line 40 |
| `kubernetes/argocd/values.yaml` | Helm values | `deploy-argocd.yml` | `--values /opt/k8s/argocd/values.yaml` line 44 |
| `kubernetes/metallb/metallb-config.yaml` | IP pool config | `cluster-networking.yml` | `kubectl apply -f /tmp/metallb-config.yaml` |
| `kubernetes/cert-manager/clusterissuer.yaml` | ClusterIssuer spec | `deploy-cert-manager.yml` | `kubectl apply -f /tmp/cert-manager/clusterissuer.yaml` |
| `/artifacts/output.json` | tunnel_id, account_id | `deploy-cloudflared.yml` | `lookup('file', '/artifacts/output.json') \| from_json` |

---

### 3. Credential Flow

Every secret — where it starts, what it becomes, where it ends up.

#### a) TF_VAR_cloudflare_api_token

```
.env: TF_VAR_cloudflare_api_token
  │
  ├─► terraform/proxmox/variables.tf: var.cloudflare_api_token
  │     → terraform/proxmox/provider.tf:
  │         provider "cloudflare" { api_token = var.cloudflare_api_token }
  │     → terraform/proxmox/cloudflare.tf:
  │         terraform_data.tunnel_config (local-exec curl)
  │         -H "Authorization: Bearer ${self.input.api_token}"
  │
  ├─► ansible/playbook/deploy-cert-manager.yml line 7:
  │     cloudflare_api_token: "{{ lookup('env', 'TF_VAR_cloudflare_api_token') }}"
  │     → kubectl create secret generic cloudflare-api-token
  │         namespace: cert-manager, key: api-token
  │     → kubernetes/cert-manager/clusterissuer.yaml:
  │         apiTokenSecretRef.name: cloudflare-api-token
  │         (cert-manager uses this for Let's Encrypt DNS-01 validation)
  │
  └─► ansible/playbook/deploy-cloudflared.yml line 11:
        cloudflare_api_token: "{{ lookup('env', 'TF_VAR_cloudflare_api_token') }}"
        → GET /accounts/{id}/cfd_tunnel/{id}/token
          Authorization: Bearer {cloudflare_api_token}
          → tunnel_token fact (see chain b below)
```

#### b) Cloudflare Tunnel Token

```
terraform/proxmox/cloudflare.tf:
  cloudflare_zero_trust_tunnel_cloudflared.homelab → tunnel created
  │
  ▼
terraform/proxmox/outputs.tf:
  output "cloudflare_tunnel_id" = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
  output "cloudflare_account_id" = var.cloudflare_account_id
  │
  ▼
/artifacts/output.json:
  { "cloudflare_tunnel_id": { "value": "<uuid>" },
    "cloudflare_account_id": { "value": "<id>" } }
  │
  ▼
ansible/playbook/deploy-cloudflared.yml:
  vars:
    terraform_output: "{{ lookup('file', '/artifacts/output.json') | from_json }}"
    tunnel_id: "{{ terraform_output.cloudflare_tunnel_id.value }}"
    account_id: "{{ terraform_output.cloudflare_account_id.value }}"
  → Cloudflare API: GET /accounts/{account_id}/cfd_tunnel/{tunnel_id}/token
  → tunnel_token_response.json.result → set_fact: tunnel_token
  │
  ▼
kubectl create secret generic cloudflared-token
  namespace: cloudflared, key: token
  │
  ▼
kubernetes/cloudflared/deployment.yaml:
  env:
    - name: TUNNEL_TOKEN
      valueFrom:
        secretKeyRef:
          name: cloudflared-token
          key: token
  args: [tunnel, --no-autoupdate, --metrics 0.0.0.0:2000, run, --token, $(TUNNEL_TOKEN)]
```

#### c) MariaDB Credentials

```
.env: MARIADB_ROOT_PASSWORD, MARIADB_PASSWORD
  │
  ▼
ansible/playbook/deploy-wordpress.yml lines 62-65:
  kubectl create secret generic wordpress-secrets
    --from-literal=mariadb-root-password="{{ lookup('env', 'MARIADB_ROOT_PASSWORD') }}"
    --from-literal=mariadb-password="{{ lookup('env', 'MARIADB_PASSWORD') }}"
    --from-literal=mariadb-database=wordpress
    --from-literal=mariadb-user=wordpress
  │
  ├─► kubernetes/wordpress/mariadb.yaml:
  │     env:
  │       MARIADB_ROOT_PASSWORD → secretKeyRef: wordpress-secrets/mariadb-root-password
  │       MARIADB_USER          → secretKeyRef: wordpress-secrets/mariadb-user
  │       MARIADB_PASSWORD      → secretKeyRef: wordpress-secrets/mariadb-password
  │       MARIADB_DATABASE      → secretKeyRef: wordpress-secrets/mariadb-database
  │
  └─► kubernetes/wordpress/wordpress.yaml:
        env:
          WORDPRESS_DB_HOST     → mariadb:3306 (hardcoded service name)
          WORDPRESS_DB_USER     → secretKeyRef: wordpress-secrets/mariadb-user
          WORDPRESS_DB_PASSWORD → secretKeyRef: wordpress-secrets/mariadb-password
          WORDPRESS_DB_NAME     → secretKeyRef: wordpress-secrets/mariadb-database
```

#### d) Grafana Admin Password

```
.env: GRAFANA_ADMIN_PASSWORD
  │
  ▼
ansible/playbook/deploy-monitoring.yml line 41:
  helm upgrade --install kube-prometheus-stack ...
    --set grafana.adminPassword={{ lookup('env', 'GRAFANA_ADMIN_PASSWORD') }}
  → Stored internally by Helm chart as a K8s secret (grafana-admin)
  → Grafana pod reads it at startup
  (Never written to a custom K8s secret — Helm manages it)
```

#### e) Ingress IP

```
.env: INGRESS_IP=192.168.1.80
  │
  ▼
ansible/playbook/cluster-networking.yml line 52:
  kubectl patch svc ingress-nginx-controller -n ingress-nginx
    -p '{"spec":{"type":"LoadBalancer","loadBalancerIP":"{{ lookup('env','INGRESS_IP') }}"}}'
  │
  ▼
MetalLB allocates 192.168.1.80 from pool defined in:
  kubernetes/metallb/metallb-config.yaml:
    IPAddressPool: 192.168.1.80-192.168.1.90
  │
  ▼
All ingress resources route through 192.168.1.80:
  kubernetes/wordpress/ingress.yaml → blog.lennardjohn.org
  kubernetes/monitoring/grafana-ingress.yaml → grafana.lennardjohn.org
  kubernetes/argocd/ingress.yaml → argocd.lennardjohn.org
```

#### f) SSH Key

```
.env: SSH_KEY_DIR=C:/Users/User/.ssh
  │
  ▼
docker-compose.yaml line 29:
  volumes: - ${SSH_KEY_DIR}:/keys:ro
  (SSH directory mounted read-only into ansible container)
  │
  ▼
scripts/build_inventory.py line 51-52 (prepare_key()):
  cp /keys/id_ed25519 /root/.ssh/id_ed25519
  chmod 600 /root/.ssh/id_ed25519
  │
  ▼
ansible/inventory/hosts.ini:
  [all:vars]
  ansible_ssh_private_key_file=/root/.ssh/id_ed25519
  ansible_ssh_common_args=-o StrictHostKeyChecking=no
  │
  ▼
All playbooks SSH into VMs using this key.
Key must match the public key hardcoded in terraform/proxmox/main.tf:
  sshkeys = "ssh-ed25519 AAAAC3Nz... ljohn@Lennard-John-PC"
```

---

### 4. Full End-to-End Chain: docker compose up → https://blog.lennardjohn.org

```
Step 1: docker compose up
  Sources: .env
  Starts: terraform container (docker/terraform/Dockerfile)

Step 2: docker/terraform/run.sh
  cd /work/terraform/proxmox
  terraform init
    Reads: terraform/proxmox/provider.tf (proxmox + cloudflare providers)
    Reads: terraform/proxmox/variables.tf (all variable definitions)
  terraform apply -auto-approve
    Reads: terraform/proxmox/main.tf
      Creates: k8s-master-01 (vmid 150, 192.168.1.70, 4GB RAM, 70GB)
      Creates: k8s-worker-1 (vmid 200, 192.168.1.71, 2GB RAM, 70GB)
      Creates: k8s-worker-2 (vmid 201, 192.168.1.72, 2GB RAM, 70GB)
    Reads: terraform/proxmox/cloudflare.tf
      Creates: Cloudflare tunnel "homelab-k8s"
      Creates: DNS CNAME → blog.lennardjohn.org
      Creates: DNS CNAME → grafana.lennardjohn.org
      Creates: DNS CNAME → argocd.lennardjohn.org
      Configures: tunnel ingress rules via Cloudflare API
    Reads: terraform/proxmox/outputs.tf
  Polls SSH on 192.168.1.70, .71, .72
  Writes: /artifacts/output.json

Step 3: ansible container starts
  Runs: scripts/build_inventory.py
    Reads: /artifacts/output.json
    Writes: ansible/inventory/hosts.ini
    Copies: SSH key to /root/.ssh/id_ed25519

Step 4: playbook.yml (all 3 nodes)
  Installs: containerd, kubelet, kubeadm, kubectl
  Control plane: kubeadm init, installs Calico CNI
  Workers: kubeadm join

Step 5: cluster-services.yml (control plane)
  Installs: Helm, NGINX ingress controller, local-path-provisioner, metrics-server

Step 6: cluster-networking.yml (control plane)
  Reads: kubernetes/metallb/metallb-config.yaml
  Installs: MetalLB, configures IP pool 192.168.1.80-90
  Patches: ingress-nginx-controller → LoadBalancer IP 192.168.1.80

Step 7: deploy-cert-manager.yml (control plane)
  Installs: cert-manager v1.14.5 via Helm
  Creates: K8s Secret cloudflare-api-token (cert-manager ns)
  Reads: kubernetes/cert-manager/clusterissuer.yaml
  Applies: ClusterIssuer letsencrypt-prod

Step 8: deploy-argocd.yml (control plane)
  Reads: kubernetes/argocd/values.yaml
  Installs: Argo CD via Helm
  Reads: kubernetes/argocd/ingress.yaml
  Applies: Ingress for argocd.lennardjohn.org
  cert-manager issues argocd-tls certificate (DNS-01 via Cloudflare)

Step 9: deploy-monitoring.yml (control plane)
  Reads: kubernetes/monitoring/values.yaml
  Installs: kube-prometheus-stack via Helm (Prometheus, Grafana, AlertManager)
  Reads: kubernetes/monitoring/kustomization.yaml
  Applies: namespace + grafana-ingress.yaml
  cert-manager issues grafana-tls certificate
  Registers: Argo CD Application "monitoring"

Step 10: deploy-wordpress.yml (control plane)
  Creates: K8s Secret wordpress-secrets (wordpress ns)
  Reads: kubernetes/wordpress/kustomization.yaml
  Applies: namespace, PVCs, mariadb deployment, wordpress deployment, ingress
  Waits: MariaDB SELECT 1 succeeds
  Runs: GRANT ALL PRIVILEGES ON wordpress.* TO 'wordpress'@'%'
  cert-manager issues wordpress-tls certificate
  Registers: Argo CD Application "wordpress"

Step 11: deploy-cloudflared.yml (control plane)
  Reads: /artifacts/output.json → tunnel_id, account_id
  Calls: Cloudflare API → fetches tunnel token
  Creates: K8s Secret cloudflared-token (cloudflared ns)
  Reads: kubernetes/cloudflared/kustomization.yaml
  Applies: namespace + cloudflared deployment (2 replicas)
  cloudflared pods connect to Cloudflare edge (4 connections registered)
  Registers: Argo CD Application "cloudflared"

Step 12: Request hits https://blog.lennardjohn.org
  Browser → Cloudflare DNS (CNAME: blog → <tunnel-id>.cfargotunnel.com)
  → Cloudflare edge → Cloudflare tunnel
  → cloudflared pod (cloudflared namespace, port 2000 metrics)
  → http://ingress-nginx-controller.ingress-nginx.svc.cluster.local
  → NGINX Ingress (192.168.1.80:443)
  → routes on Host: blog.lennardjohn.org
  → Service: wordpress:80 (wordpress namespace)
  → WordPress pod (wordpress:php8.2-apache)
  → reads wordpress-secrets for DB credentials
  → connects to mariadb:3306 (ClusterIP service)
  → MariaDB pod reads wordpress-secrets
  → returns page
```

---

### 5. GitOps Chain: git push → live update (Argo CD)

```
Developer edits kubernetes/wordpress/wordpress.yaml (e.g. changes image tag)
  │
  ▼
git push origin main
  │
  ▼
Argo CD Application controller (polls every 3 minutes, or webhook-triggered):
  Reads: kubernetes/argocd/apps/wordpress.yaml
    repoURL: https://github.com/Lennardj/homelab-blog
    targetRevision: main
    path: kubernetes/wordpress
  Compares: live cluster state vs repo state
  Detects: diff in wordpress.yaml
  │
  ▼
Argo CD runs: kubectl apply -k kubernetes/wordpress/
  Reads: kubernetes/wordpress/kustomization.yaml
  Applies: namespace.yaml, pvc.yaml, mariadb.yaml, wordpress.yaml, ingress.yaml
  (secrets.yaml excluded — not in kustomization.yaml, created by Ansible)
  │
  ▼
Kubernetes rolling update:
  New WordPress pod created with updated image
  Old pod terminated after health checks pass
  Zero downtime if resources allow
  │
  ▼
Argo CD UI (argocd.lennardjohn.org):
  Application "wordpress": Synced ✅ Healthy ✅
```

---

### 6. Why Secrets Stay Outside Git

| Secret | Why it can't be in Git | Where it lives |
|--------|----------------------|----------------|
| `wordpress-secrets` | Contains real DB passwords | K8s Secret, created by Ansible from `.env` |
| `cloudflared-token` | Tunnel token rotates; fetched live from Cloudflare API | K8s Secret, created by Ansible |
| `cloudflare-api-token` | Cloudflare API key — full DNS + tunnel access | K8s Secret in cert-manager ns |
| Grafana password | Admin credential | Helm-managed K8s Secret (not custom) |
| `wordpress-tls`, `grafana-tls`, `argocd-tls` | TLS private keys | Auto-created by cert-manager, never in Git |

Argo CD only manages K8s resources that are safe to commit. Secrets are seeded by Ansible before Argo CD first syncs — that's why Application CRs are registered at the end of each Ansible playbook, not at Argo CD install time.

---

## How This Document Was Built

This manual is reconstructed from real project chat history across multiple LLM sessions. Every command, error, config value, and architectural decision mentioned in those transcripts is captured here — including mistakes, wrong turns, and the reasoning behind each fix.

It is intended as:
- A **forensic record** of the project from scratch to production
- An **interview study guide** — every section answers "why did you do it that way?"
- A **runbook** for repeating or extending the deployment

---

### Feature: Landing Page — lennardjohn.org

**Date:** 2026-03-30

**What was built:** A personal portfolio landing page served at `lennardjohn.org` (root domain). Dark terminal-style design with green accents, nginx serving static HTML from a Kubernetes ConfigMap.

**Architecture:**
```
kubernetes/landing/
  namespace.yaml      # landing namespace
  configmap.yaml      # index.html (full HTML/CSS, no external build step)
  deployment.yaml     # nginx:alpine, mounts ConfigMap as /usr/share/nginx/html
  ingress.yaml        # lennardjohn.org, letsencrypt-staging
  kustomization.yaml  # lists all resources (no secrets)

kubernetes/argocd/apps/landing.yaml   # Argo CD Application CR
ansible/playbook/deploy-landing.yml   # 9th playbook in pipeline
```

**Why ConfigMap for HTML:** The HTML lives in Git. No Docker image build, no registry. Updating the page = edit `configmap.yaml` → `git push` → Argo CD applies the ConfigMap update → nginx serves new content automatically. Pure GitOps with zero infrastructure overhead for a static page.

**Cloudflare changes:**
- Added `cloudflare_dns_record.landing` with `name = "@"` (root domain CNAME flattening)
- Added `lennardjohn.org` as first entry in tunnel ingress rules

**Page sections:**
1. Name + blinking cursor + role
2. Bio — stack description
3. `// homelab` — Blog, Grafana, Argo CD service links
4. `// find me` — YouTube, GitHub, LinkedIn, Dev.to icon links (Font Awesome CDN)
5. Stack tags — Kubernetes, Terraform, Ansible, Argo CD, Prometheus, Cloudflare, Docker, Linux

**Interview talking point:** Serving a static site from a Kubernetes ConfigMap is intentionally over-engineered for a homelab — but it demonstrates that even trivial workloads benefit from GitOps. Any change to the landing page goes through the same pipeline as a production deployment: code review, git history, automated reconciliation. The operational model is identical whether you're deploying a static HTML page or a stateful database cluster.

---

### Incident #18 — Nginx ssl-redirect Loop Through Cloudflare Tunnel

**Date:** 2026-03-30
**Symptom:** Site works on local machine but all other devices get "too many redirects" error.

**Root cause:** nginx ingress had `ssl-redirect: true`. Cloudflare tunnel forwards traffic to nginx as HTTP internally. nginx sees HTTP and issues a 301 to HTTPS. The browser follows the redirect back through Cloudflare → tunnel → nginx (HTTP again) → 301 again → infinite loop. Local machine bypassed the loop by resolving directly to the MetalLB IP rather than going through the Cloudflare tunnel.

**Fix:** Set `nginx.ingress.kubernetes.io/ssl-redirect: "false"` on all three ingresses.

```yaml
# Before
nginx.ingress.kubernetes.io/ssl-redirect: "true"

# After
nginx.ingress.kubernetes.io/ssl-redirect: "false"
```

**Why this is safe:** Cloudflare enforces HTTPS at its edge — browsers can only reach the site via HTTPS through Cloudflare. nginx never sees a raw internet HTTP request, so there is nothing to upgrade. The ssl-redirect annotation is only needed when nginx is directly internet-facing.

**Interview talking point:** This is a classic reverse proxy layering issue. When you have two layers both trying to enforce HTTPS (Cloudflare + nginx), you get a redirect loop. The rule is: only the outermost layer should enforce the protocol upgrade. Everything behind it should trust the upstream and serve content directly.

---

### Incident #17 — MariaDB OOMKill During Init: wordpress Database Never Created

**Date:** 2026-03-30
**Symptom:** WordPress shows "Error establishing a database connection" on every request. MariaDB pod is `1/1 Running` with 1 restart.

**Diagnostic:**
```bash
kubectl exec -n wordpress deployment/mariadb -- mariadb -uroot -e "SHOW DATABASES;"
# Result: information_schema, mysql, performance_schema, sys
# wordpress database missing
```

**Root cause:** MariaDB was OOMKilled (exit code 137, memory limit 512Mi) during first-time initialization. The `MARIADB_DATABASE` environment variable triggers database creation as part of the init script. When the container is killed mid-init, the data directory is partially written. On restart, MariaDB detects the data directory already exists and skips re-initialization — so the `wordpress` database is never created.

The existing Ansible GRANT task (`GRANT ALL PRIVILEGES ON wordpress.*`) does not create the database — it only grants permissions on it. If the database doesn't exist, the GRANT succeeds silently but WordPress still can't connect.

**Fix:** Add an explicit `CREATE DATABASE IF NOT EXISTS` task in `deploy-wordpress.yml` before the GRANT:

```yaml
- name: Ensure wordpress database exists
  shell: |
    kubectl exec -n wordpress deployment/mariadb -- \
      mariadb -uroot \
      -e "CREATE DATABASE IF NOT EXISTS wordpress;"
  register: db_result
  retries: 30
  delay: 30
  until: db_result.rc == 0
```

`IF NOT EXISTS` makes this idempotent — if MariaDB initialized correctly and the database already exists, the statement is a no-op.

**Interview talking point:** Never rely solely on a container's init script to create critical state. If the container can be OOMKilled or interrupted, that state may never be created. Idempotent infrastructure-as-code (Ansible `CREATE IF NOT EXISTS`) is the correct pattern — it works whether the automated init ran or not.

---

### Incident #16 — Remote Access via Tailscale: Subnet Routing for Full Pipeline

**Date:** 2026-03-30
**Context:** Running `docker compose up` from a remote machine (not on the home LAN) via Tailscale. Terraform can reach Proxmox via the Tailscale IP, but Ansible times out trying to SSH to the VMs.

**Root cause:** Tailscale by default only gives access to devices enrolled in the tailnet. The Kubernetes VMs (`192.168.1.70–.72`) are not enrolled in Tailscale — they are plain LAN devices. Without subnet routing, a remote machine cannot reach `192.168.1.x` addresses through Tailscale.

**Fix: Enable Tailscale subnet routing on the Proxmox host**

Step 1 — On the Proxmox host (SSH in via Tailscale IP):
```bash
tailscale up --advertise-routes=192.168.1.0/24 --accept-routes
```

Step 2 — In the Tailscale admin console (`login.tailscale.com`):
- Machines → find Proxmox host → three dots → Edit route settings
- Enable `192.168.1.0/24`

Step 3 — On the remote Windows machine running docker compose:
```bash
tailscale up --accept-routes
```

**What changes in .env for a remote run:**
```bash
# Change this to your Proxmox host's Tailscale IP:
TF_VAR_proxmox_api_url=https://<tailscale-ip>:8006/api2/json

# Everything else stays the same — VM IPs (192.168.1.70-.72), INGRESS_IP,
# SSH_KEY_DIR are all local to the machine running compose.
```

**Why only the Proxmox URL changes:** Terraform provisions VMs with static IPs on the local LAN (`192.168.1.70–.72`). These IPs belong to the VMs themselves — they don't change based on where compose runs. With subnet routing enabled, the remote machine routes `192.168.1.0/24` through the Proxmox host via Tailscale, making all VM IPs reachable exactly as if you were on the home network.

**Interview talking point:** Tailscale subnet routing turns a Tailscale node into a relay for an entire LAN subnet — without installing Tailscale on every device. The Proxmox host acts as an exit node for the `192.168.1.0/24` subnet. This is the same pattern used in enterprise VPN split-tunnelling, but implemented at zero cost with WireGuard-based mesh networking.

---

### Incident #15 — Let's Encrypt Rate Limit: 5 Certs Per Exact Domain Set Per Week

**Date:** 2026-03-29
**Symptom:** cert-manager CertificateRequest stuck in `errored` state:
```
Failed to create Order: 429 urn:ietf:params:acme:error:rateLimited:
too many certificates (5) already issued for this exact set of identifiers
in the last 168h0m0s, retry after 2026-03-29 20:19:51 UTC
```

**Root cause:** Let's Encrypt enforces a limit of 5 duplicate certificates (same exact hostnames) per 7 days. Multiple `docker compose up` test runs each triggered a fresh cert request for `blog.lennardjohn.org`, exhausting the quota.

**Fix (short term):** Wait for the 168h window to expire. Then force cert-manager to retry:
```bash
kubectl delete certificate wordpress-tls -n wordpress
# cert-manager recreates it immediately and issues successfully
```

**Fix (long term):** Add a staging ClusterIssuer. Use `letsencrypt-staging` in all ingress annotations during test runs. Switch to `letsencrypt-prod` only for the final video run:
```bash
# Switch to prod before recording:
sed -i 's/letsencrypt-staging/letsencrypt-prod/g' \
  kubernetes/wordpress/ingress.yaml \
  kubernetes/monitoring/grafana-ingress.yaml \
  kubernetes/argocd/ingress.yaml
```

**Interview talking point:** Let's Encrypt staging has no rate limits and uses a separate CA. Staging certs are browser-untrusted but functionally identical for testing DNS-01 challenge flows. Always develop against staging, use prod only when you need a trusted cert.

---

### Incident #14 — WordPress Pod Stuck 0/1: Two Compounding Issues

**Date:** 2026-03-29

**Symptom 1:** WordPress pod `0/1 Running` indefinitely. Readiness probe failing with HTTP 500 from the very first check.

**Root cause 1:** The readiness probe was `httpGet GET /`. WordPress returns HTTP 500 on a fresh install before the setup wizard is completed — there are no tables in the database yet. The pod is permanently not-ready, so the Service never routes traffic to it, and the user can never reach the setup wizard to fix it. Classic chicken-and-egg deadlock.

**Fix:** Change readiness probe from `httpGet` to `tcpSocket`. Apache listening on port 80 is the correct signal that the container is ready to receive traffic — the WordPress application state is irrelevant at pod startup.

```yaml
# Before
readinessProbe:
  httpGet:
    path: /
    port: 80

# After
readinessProbe:
  tcpSocket:
    port: 80
```

**Symptom 2:** After the probe fix was applied, a new pod was created but stayed `0/1`. `kubectl get rs -n wordpress` showed two ReplicaSets both with `DESIRED: 1`.

**Root cause 2:** `wordpress-pvc` is `ReadWriteOnce`. During a rolling update, Kubernetes creates the new pod before terminating the old one. If the new pod lands on a different node, it cannot mount the PVC that is already attached to the old pod on the original node. K8s won't kill the old pod until the new one is Ready — but the new pod can never be Ready without the PVC. Deadlock.

**Fix:** Add `strategy: Recreate` to the Deployment. Kubernetes terminates all old pods first (releasing the PVC), then starts the new pod.

```yaml
spec:
  strategy:
    type: Recreate
```

**Interview talking point:** `RollingUpdate` is the right strategy for stateless workloads. For stateful workloads with `ReadWriteOnce` PVCs, `Recreate` is required — it trades zero-downtime rollout for guaranteed PVC availability. If zero downtime is critical, the correct solution is `ReadWriteMany` storage (e.g. NFS, CephFS) so multiple pods can mount simultaneously.

---

### Incident #13 — MariaDB 11.8 unix_socket Auth: Root Password Rejected

**Date:** 2026-03-29
**Symptom:** `Wait for MariaDB to accept connections` exhausted all 30 retries. MariaDB pod was `1/1 Running`. Logs showed repeated:
```
Access denied for user 'root'@'localhost' (using password: YES)
```

**Diagnostic steps:**
```bash
kubectl exec -n wordpress deployment/mariadb -- mariadb --version
# mariadb from 11.8.6-MariaDB — binary exists

kubectl exec -n wordpress deployment/mariadb -- mariadb -uroot -p"change-me-root" -e "SELECT 1"
# ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: YES)

kubectl exec -n wordpress deployment/mariadb -- mariadb -uroot -e "SELECT 1"
# 1  ← works instantly
```

**Root cause:**
MariaDB 11.8 changed the default root authentication plugin to `unix_socket`. With this plugin, root login is tied to the OS user running the process — password authentication is explicitly disabled for root. The `kubectl exec` command runs as root inside the container, so passwordless login works. Any attempt to use `-p` fails regardless of whether the password is correct.

This is a **version behaviour change** — MariaDB 10.x used password auth for root by default. The `secrets.yaml` passwords and `.env` values were all correct; the issue was purely the auth plugin change in 11.8.

**Fix applied:**
Removed `-p` flag from both root-authenticated commands in `deploy-wordpress.yml`:

```yaml
# Before
mariadb -uroot -p"{{ lookup('env', 'MARIADB_ROOT_PASSWORD') }}" -e "SELECT 1"
mariadb -uroot -p"{{ lookup('env', 'MARIADB_ROOT_PASSWORD') }}" -e "GRANT ..."

# After
mariadb -uroot -e "SELECT 1"
mariadb -uroot -e "GRANT ..."
```

**Security consideration:**
`unix_socket` auth is actually **more secure** than password auth for root. Root can only authenticate from inside the container via `kubectl exec` — there is no remote root login path. The wordpress app user still uses password auth (`MARIADB_PASSWORD`) and only has `wordpress.*` privileges.

**Interview talking point:** Always check the default authentication plugin when upgrading database versions — MariaDB 11.x and MySQL 8.x both changed root auth defaults in ways that break automation scripts written for older versions. The fix is to either explicitly set the auth plugin in the MariaDB config, or adapt the automation to use passwordless socket auth. Socket auth is the more secure choice for internal health checks and admin tasks.

---

### Incident #12 — Argo CD Implementation: Four Bugs Found in One Review

**Date:** 2026-03-29
**Context:** After writing the initial Argo CD implementation, a pre-deploy review of all manifests and playbooks identified four bugs before the code ever ran.

**Bug 1 — Task ordering: namespace applied before files existed**
`deploy-argocd.yml` had "Apply argocd namespace" as the first task, referencing `/opt/k8s/argocd/namespace.yaml`. But the tasks to create that directory and copy files to it came *after* this task. The file didn't exist at the time of the apply.

Fix: moved "Ensure directory exists" and "Copy manifests" to the top of the playbook, before any `kubectl` calls.

**Bug 2 — Helm install retries missed in 30/30 standardisation**
The Helm install task had `retries: 20` — missed during the global 30/30 pass because it already had `delay: 30`. The grep-based check only caught `retries: 20, delay: 20` pairs.

Fix: set `retries: 30` on the Helm install task.

**Bug 3 — Monitoring Application CR would fail: values.yaml is not a K8s manifest**
`kubernetes/monitoring/` contains `values.yaml` — a Helm values file. Argo CD syncs a directory by applying all files in it as K8s resources. `kubectl apply -f values.yaml` would throw: `no kind is registered for the type`.

Fix: added `kustomization.yaml` to `kubernetes/monitoring/` listing only `namespace.yaml` and `grafana-ingress.yaml`. Same fix applied to `kubernetes/cloudflared/`. Both Ansible and Argo CD now use `kubectl apply -k`, ensuring they apply exactly the same resources.

**Bug 4 — Application CRs registered before secrets existed**
All three Application CRs were applied at the end of `deploy-argocd.yml` (step 5 in the pipeline). But `wordpress-secrets` is created in step 7 and `cloudflared-token` is created in step 8. Argo CD would immediately begin syncing, find the deployments referencing missing secrets, and pods would crashloop.

Fix: removed Application CR applies from `deploy-argocd.yml`. Each CR is now applied at the end of its respective playbook, after its secrets are created:
- `deploy-monitoring.yml` → applies `apps/monitoring.yaml`
- `deploy-wordpress.yml` → applies `apps/wordpress.yaml`
- `deploy-cloudflared.yml` → applies `apps/cloudflared.yaml`

**Interview talking point:** Pre-deploy code review caught all four bugs before a single run. The most common class of bug in Ansible playbooks is ordering — tasks that reference files, resources, or state that doesn't exist yet. Reading the playbook top-to-bottom as if you were the target machine is the fastest way to catch these. The kustomization.yaml alignment bug is a good example of impedance mismatch between tools — Argo CD and Ansible must agree on what "apply this directory" means, or they'll diverge silently.

---

### Incident #11 — Comprehensive Timing Audit: Standardising to 30/30 for Slow Hardware

**Date:** 2026-03-29
**Context:** After several timeouts on old hardware (cloudflared rollout, apt lock, MariaDB socket), a full audit of all retry/delay/timeout values was performed across all 7 playbooks in one pass.

**Problem pattern identified:**
All wait tasks had been written with `retries: 20, delay: 20` (400s max). On slow homelab hardware with a 100Mbps residential connection, this was consistently hitting limits:
- Image pulls: 2m20s for cloudflared, similar for other images
- MariaDB init: 60-90s before socket available
- apt operations: could hold the lock for 5+ minutes

A secondary issue was found: the workers' cloud-init wait used `cloud-init status --wait` (blocking, returns rc=1 on error state) instead of the non-blocking pattern already fixed on `k8s_all`.

**Changes applied:**

| Change | Before | After |
|--------|--------|-------|
| All pod wait retries/delays | 20/20 (400s) | 30/30 (900s) |
| cert-manager webhook rollout | `--timeout=120s` | `--timeout=600s` |
| MariaDB connection check | 20 retries × 10s | 30 retries × 30s |
| MariaDB GRANT retries | 5 × 10s | 30 × 30s |
| Workers cloud-init | `--wait` + `rc==0` | non-blocking + `'running' not in stdout` |
| SSH waits | 20 × 20s | 20 × 60s (boot tolerance) |

SSH waits kept at 20 retries but increased to 60s delay — a VM takes time to boot and SSH to start, longer delays reduce noisy retry output.

**Interview talking point:** Timeout values are environment-specific. What works on a GKE cluster with 10Gbps registry pulls will fail on a homelab with a slow residential connection and old hardware. Always audit timeouts when moving to a new environment. The rule of thumb: set max wait to 3-4x the observed worst case, not the average case. For a homelab video demo, reliability matters more than speed — a 15-minute wait that always succeeds beats a 5-minute wait that fails 30% of the time.

---

### Incident #10 — GRANT Fails: MariaDB Socket Not Ready (Running ≠ Ready)

**Date:** 2026-03-29
**Symptom:** The `Ensure wordpress user has grants from any host` task failed all 5 retries:
```
ERROR 2002 (HY000): Can't connect to local server through socket '/run/mysqld/mysqld.sock' (2)
command terminated with exit code 1
```

**Root cause:**
The preceding wait task checked if the MariaDB pod was in `Running` state:
```yaml
until: mariadb_ready.stdout|int >= 1  # checks Running pod count
```
`Running` means the container process started — not that MariaDB finished initializing. MariaDB performs first-boot initialization (creating system tables, creating the wordpress user/database) before it creates the Unix socket and starts accepting connections. The GRANT task fired while MariaDB was still in this init phase — the socket didn't exist yet.

**Fix applied:**
Replaced the pod state check with an actual connection check using `SELECT 1`:
```yaml
- name: Wait for MariaDB to accept connections
  shell: |
    kubectl exec -n wordpress deployment/mariadb -- \
      mariadb -uroot -p"{{ lookup('env', 'MARIADB_ROOT_PASSWORD') }}" -e "SELECT 1"
  register: mariadb_ready
  retries: 20
  delay: 10
  until: mariadb_ready.rc == 0
  failed_when: false
```

This retries until MariaDB actually responds to a query — guaranteeing the socket exists and the server is accepting connections before GRANT runs.

**Interview talking point:** `Running` state in Kubernetes means the container's main process is running — it does not mean the application inside is ready to serve requests. This distinction is exactly what readiness probes exist for. When driving application logic from Ansible (outside the cluster), you must implement your own readiness gate. `SELECT 1` is the standard MariaDB health check — it's fast, stateless, and fails clearly if the server isn't ready.

---

### Incident #9 — WordPress HTTP 500 (Stale MariaDB PVC, Host Not Allowed)

**Date:** 2026-03-29
**Symptom:** WordPress pod Running but never Ready. Readiness probe failing with HTTP 500 for 8+ hours, 3279 failures. No restarts (liveness TCP probe passing fine).

```
Warning  Unhealthy  56s (x3279 over 8h)  kubelet  Readiness probe failed: HTTP probe failed with statuscode: 500
```

**Diagnostic steps:**

```bash
kubectl logs -n wordpress deployment/wordpress --tail=50
# 192.168.1.71 - - GET / HTTP/1.1" 500 2757 "kube-probe/1.30"
# (repeated every 10s — only Apache access log, no PHP errors visible)

kubectl get pods,svc -n wordpress
# mariadb: 1/1 Running, 1 restart (8h ago)
# wordpress: 0/1 Running, 0 restarts
# service/mariadb: ClusterIP 10.103.238.36:3306

kubectl get secret wordpress-secrets -n wordpress -o jsonpath='{.data.mariadb-password}' | base64 -d
# change-me-app  ← correct value

# Direct PHP connection test from WordPress pod:
kubectl exec -n wordpress deployment/wordpress -- bash -c \
  "php -r \"\\\$c=new mysqli('mariadb','wordpress','change-me-app','wordpress');echo \\\$c->connect_error?:'Connected OK';\""
# PHP Fatal error: Host '10.96.230.12' is not allowed to connect to this MariaDB server

kubectl exec -n wordpress deployment/mariadb -- mariadb -uroot -pchange-me-root -e "SELECT 1"
# ERROR 1045: Access denied for user 'root'
```

**Root cause analysis:**

Two issues working together:

**Issue 1: Stale PVC data**
Local-path-provisioner stores data on the node filesystem at `/opt/local-path-provisioner/`. When Ansible is re-run against existing VMs without a full Terraform teardown (e.g. re-running `docker-compose up`), the MariaDB PVC persists with old data. On startup, MariaDB detects an existing data directory and **skips re-initialization entirely** — `MARIADB_USER`, `MARIADB_PASSWORD`, `MARIADB_ROOT_PASSWORD` env vars are all ignored. The old user accounts remain with whatever host restrictions they had from the previous run.

**Issue 2: User host grant mismatch**
The `wordpress` MariaDB user was created with a restricted host (not `%`). When pod IPs change between cluster rebuilds (which they always do), the existing user grant no longer matches the new pod IP — hence `Host '10.96.230.12' is not allowed`.

The root password denial confirmed the stale data — the root password in the current secret didn't match what was stored in the old data directory.

**Fix applied:**
Added a post-deploy task in `deploy-wordpress.yml` that explicitly grants the wordpress user wildcard host access after every deploy:

```yaml
- name: Wait for MariaDB to be ready
  shell: |
    kubectl get pods -n wordpress --no-headers | (grep mariadb | grep Running || true) | wc -l
  register: mariadb_ready
  retries: 20
  delay: 10
  until: mariadb_ready.stdout|int >= 1

- name: Ensure wordpress user has grants from any host
  shell: |
    kubectl exec -n wordpress deployment/mariadb -- \
      mariadb -uroot -p"{{ lookup('env', 'MARIADB_ROOT_PASSWORD') }}" \
      -e "GRANT ALL PRIVILEGES ON wordpress.* TO 'wordpress'@'%' IDENTIFIED BY '{{ lookup('env', 'MARIADB_PASSWORD') }}'; FLUSH PRIVILEGES;"
  register: grant_result
  retries: 5
  delay: 10
  until: grant_result.rc == 0
```

**Security consideration:**
`'wordpress'@'%'` allows the user to connect from any IP. This is acceptable because MariaDB is a `ClusterIP` service — port 3306 is not reachable outside the Kubernetes cluster. The wordpress user only has access to the `wordpress` database. A hardened production setup would add a `NetworkPolicy` restricting MariaDB access to only the WordPress pod.

**Interview talking points:**
- Docker/containerd volume mounts and Kubernetes PVCs are stateful. Re-running a deployment pipeline does not automatically wipe old data — you must explicitly handle idempotency for stateful services.
- MariaDB (and MySQL) env vars like `MARIADB_USER` are init-only — they run once on first boot when the data directory is empty. This is documented behaviour but easy to forget. Always verify user grants after deploy rather than assuming env vars applied.
- `Host 'x.x.x.x' is not allowed to connect` (Error 1130) is a host grant issue, not a password issue. The user exists but doesn't have permission from that source IP. Always check `SELECT user, host FROM mysql.user` when debugging connection issues.

---

### Incident #8 — cloudflared Rollout Timeout (Slow Image Pull on Old Hardware)

**Date:** 2026-03-29
**Symptom:** `deploy-cloudflared.yml` failed with "cloudflared rollout timed out". The rescue block fired and Ansible exited with code 2.

```
fatal: [k8s-master-01]: FAILED! => {"msg": "cloudflared rollout timed out - see pod describe and logs above"}
```

**Diagnostic commands run:**
```bash
kubectl get pods -n cloudflared
# NAME                           READY   STATUS    RESTARTS   AGE
# cloudflared-75c67c554b-8xbt8   1/1     Running   0          43m
# cloudflared-75c67c554b-jqwqh   1/1     Running   0          43m

kubectl describe pods -n cloudflared
# Pod 1 image pull: 1m6.564s
# Pod 2 image pull: 2m20.474s (including waiting)

kubectl logs -n cloudflared -l app=cloudflared --tail=50
# INF Registered tunnel connection connIndex=0 ... location=akl01
# INF Registered tunnel connection connIndex=1 ... location=wlg01
# INF Registered tunnel connection connIndex=2 ... location=akl01
# INF Registered tunnel connection connIndex=3 ... location=wlg01
```

**Key observation:** Both pods were `Running` and `Ready` with 0 restarts. The tunnel had all 4 connections registered to Cloudflare edge. cloudflared was working perfectly — Ansible just gave up before the pods finished starting.

**Root cause:**
The rollout timeout was `120s`. Pod 2's image pull alone took `2m20s` — longer than the entire timeout. On old hardware with a slow internet connection, pulling a 27MB image can take several minutes. `kubectl rollout status` waits for all replicas to become Ready, but gave up at 120s while the second pod was still pulling its image.

**Fix applied:**
```yaml
# Before
command: kubectl rollout status deployment/cloudflared -n cloudflared --timeout=120s

# After
command: kubectl rollout status deployment/cloudflared -n cloudflared --timeout=600s
```

**Interview talking point:** Always size rollout timeouts to your environment. Cloud clusters with fast registries can pull images in seconds — homelab hardware on a residential connection can take minutes. A rollout timeout failure does not mean the deployment is broken; always check pod status and logs before concluding there is an application error. The rescue block (pod describe + logs) is what enabled fast diagnosis here.

---

### Incident #7 — apt-daily.timer Restarting unattended-upgrades Mid-Playbook

**Date:** 2026-03-28
**Symptom:** `Install kubelet, kubeadm, kubectl` failed on all nodes with:
```
E: Unable to acquire the dpkg frontend lock (/var/lib/dpkg/lock-frontend), is another process using it?
```
This happened even though a dedicated task had already stopped `unattended-upgrades` and the apt lock wait had passed earlier in the playbook.

**Key clue:** The Ansible apt module already had `DPkg::Lock::Timeout=60` set — it waited a full 60 seconds and still couldn't acquire the lock. Something was actively holding it for over a minute.

**Root cause:**
`unattended-upgrades` is managed by two systemd timers:
- `apt-daily.timer` — triggers `apt-get update` cache refresh
- `apt-daily-upgrade.timer` — triggers the actual unattended upgrade

When `systemctl stop unattended-upgrades` ran earlier in the playbook, it stopped the service process. But these timers were still active. By the time Ansible reached the kubelet install (several minutes later), one of the timers had fired and restarted the service — which then re-acquired the dpkg lock to run a full upgrade.

**Fix applied:**
Stop and disable all three — the service and both timers:
```yaml
- name: Stop and disable unattended-upgrades service and timers
  systemd:
    name: "{{ item }}"
    state: stopped
    enabled: false
  loop:
    - unattended-upgrades
    - apt-daily.timer
    - apt-daily-upgrade.timer
  failed_when: false
```

**Why `enabled: false`:**
`state: stopped` only stops them for this boot. `enabled: false` prevents them from starting again on next boot — important if the playbook is re-run after a reboot. `failed_when: false` handles the case where a timer doesn't exist on minimal images.

**Interview talking point:** On Ubuntu, `unattended-upgrades` is not just a service — it's driven by systemd timers. A common mistake is to stop the service and assume the problem is solved, only to have the timer restart it minutes later. Always stop the timers AND the service. On systems where you need apt to be stable for long operations (cluster bootstrap, large installs), disabling the timers for the duration is the correct approach.

---

### Incident #6 — Helm Not Found on cert-manager Playbook

**Date:** 2026-03-28
**Symptom:** `deploy-cert-manager.yml` failed immediately on `Add Jetstack Helm repo` with:
```
fatal: [k8s-master-01]: FAILED! => {"msg": "Error executing command.", "rc": 2, "stderr": "", "stdout": ""}
[ERROR]: Error executing command: [Errno 2] No such file or directory: b'helm'
```
All 20 retries failed instantly — `helm` binary did not exist on the node.

**Root cause:**
Helm was only installed in `deploy-monitoring.yml` (playbook #5 in the execution order). `deploy-cert-manager.yml` is playbook #4 — it runs before monitoring. When cert-manager tried to run `helm repo add jetstack`, the binary wasn't on the node yet.

Execution order in `build_inventory.py`:
```
1. playbook.yml             (K8s prereqs + kubeadm)
2. cluster-services.yml     (NGINX, storage, metrics-server)
3. cluster-networking.yml   (MetalLB)
4. deploy-cert-manager.yml  ← helm used here
5. deploy-monitoring.yml    ← helm was only installed here
6. deploy-wordpress.yml
7. deploy-cloudflared.yml
```

**Fix applied:**
Moved helm install to `cluster-services.yml` (position 2) so it is available to all subsequent playbooks. Removed the duplicate from `deploy-monitoring.yml`.

`cluster-services.yml`:
```yaml
- name: Install Helm
  shell: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  args:
    creates: /usr/local/bin/helm
```

`deploy-monitoring.yml` — removed the duplicate helm install block.

**Why `creates: /usr/local/bin/helm`:**
This makes the task idempotent — if helm is already installed the shell command is skipped entirely. Without it, every playbook run would re-download and re-install helm unnecessarily.

**Interview talking point:** Playbook execution order matters. Shared dependencies (helm, kubectl plugins, etc.) should be installed as early as possible in the pipeline — ideally in a dedicated "platform tools" playbook that all subsequent playbooks can rely on. Installing a tool in the same playbook that first needs it is fine for isolated runs but breaks when other playbooks need it earlier.

---

### Incident #5 — apt-get update Failing Silently (No DNS on Static IPs + ciupgrade Lock)

**Date:** 2026-03-28
**Symptom:** All three nodes failed at `Install required packages` with a blank error message: `"Failed to update apt cache after 5 retries: "`. No actual error text — just an empty string. This happened even after the cloud-init fix (Incident #4) was applied.

```
fatal: [k8s-master-01]: FAILED! => {"changed": false, "msg": "Failed to update apt cache after 5 retries: "}
fatal: [k8s-worker-1]: FAILED! => {"changed": false, "msg": "Failed to update apt cache after 5 retries: "}
fatal: [k8s-worker-2]: FAILED! => {"changed": false, "msg": "Failed to update apt cache after 5 retries: "}
```

**Initial suspicion — apt lock still held:**
The playbook already had a lock-wait task (`fuser /var/lib/dpkg/lock-frontend`) that passed (ok=8). But `apt-get update` still failed immediately. The blank error message hid the real cause.

**Debugging approach:**
Compared current state against the last known working commit (`85bfd63`) via `git show`. The apt task itself was identical. The only structural change since the last working run was switching VMs from `ip=dhcp` to static IPs in Terraform.

**Root cause — two issues compounding:**

**Issue 1: No DNS configured on static IPs**

When VMs used DHCP (`ip=dhcp`), the DHCP lease automatically provided DNS server addresses. When switched to static IPs using only:
```hcl
ipconfig0 = "ip=192.168.1.70/24,gw=192.168.1.254"
```
no DNS server was configured. The VMs had network connectivity and SSH worked (proven by ok=8 in the play recap), but `apt-get update` couldn't resolve `archive.ubuntu.com` — DNS failure. The Ansible apt module swallows the resolver error and reports a blank message.

**Why SSH worked but DNS didn't:** SSH connects to an IP address directly — no DNS needed. `apt-get update` connects to hostnames (`archive.ubuntu.com`, `security.ubuntu.com`) — requires DNS.

**Issue 2: `ciupgrade = true` + unattended-upgrades re-acquiring apt lock**

Even with the lock-wait task passing briefly, `unattended-upgrades` (still running as a systemd service) could re-acquire the apt lock between the check and the actual `apt-get update` run. On slow hardware this race condition is more likely.

**Fix applied:**

`terraform/proxmox/main.tf` — add nameserver and disable ciupgrade on both VMs:
```hcl
# Before
ipconfig0 = "ip=${var.master_ip}/24,gw=${var.vm_gateway}"
ciupgrade  = true

# After
ipconfig0  = "ip=${var.master_ip}/24,gw=${var.vm_gateway}"
nameserver = "8.8.8.8 8.8.4.4"
ciupgrade  = false
```

`ansible/playbook/playbook.yml` — stop unattended-upgrades before any apt task:
```yaml
- name: Stop unattended-upgrades to prevent apt lock conflicts
  systemd:
    name: unattended-upgrades
    state: stopped
  failed_when: false
- name: Fix any partial dpkg state left by unattended-upgrades
  command: dpkg --configure -a
  failed_when: false
  changed_when: false
```

**Why `dpkg --configure -a` after stopping it:**
If `unattended-upgrades` was mid-run when stopped, dpkg could be left in a partial configuration state. `dpkg --configure -a` completes any pending package configurations before we touch apt, ensuring a clean state.

**Why `failed_when: false` on both tasks:**
`systemctl stop` may fail if the service doesn't exist (e.g. minimal image). `dpkg --configure -a` may produce warnings but still be safe to proceed. Neither failure should abort the playbook.

**Interview talking points:**
- A blank apt error message almost always means DNS failure or network unreachability — the package manager can't report what it can't reach. Always check DNS first: `ping archive.ubuntu.com`.
- Static IPs in cloud-init require explicit DNS configuration. DHCP gives you DNS for free; static IPs do not. This is easy to miss because other network functionality (SSH, ping by IP) works fine without DNS.
- `ciupgrade = true` in Terraform/cloud-init is a hidden apt lock risk. On Ubuntu 24.04, `unattended-upgrades` runs on first boot AND cloud-init tries to run `apt-get upgrade` — two processes competing for the same lock. Disabling `ciupgrade` removes one of the two contenders.
- Stopping `unattended-upgrades` before running apt tasks is safe — it's a background housekeeping service, not a dependency of any package install. It restarts on the next scheduled run automatically.

---

### Incident #4 — cloud-init status: error on All Nodes

**Date:** 2026-03-28
**Symptom:** All three nodes failed at `Wait for cloud-init to finish (resilient)` after 20 retries. SSH was working (ok=2 on each node).

```
fatal: [k8s-master-01]: FAILED! => {"stdout": "status: error", "rc": 1}
fatal: [k8s-worker-1]: FAILED! => {"stdout": "status: error", "rc": 1}
fatal: [k8s-worker-2]: FAILED! => {"stdout": "status: error", "rc": 1}
```

**Key observation:** The delta was `0:00:00.296` — the command returned almost instantly, meaning cloud-init had already finished. This ruled out a timing issue — cloud-init wasn't still running, it had completed with an error state.

**Root cause:** `ciupgrade: true` in Terraform tells Proxmox cloud-init to run `apt-get upgrade` on first boot. Ubuntu 24.04's `unattended-upgrades` service runs concurrently on first boot and holds the apt lock. cloud-init's upgrade attempt fails because it can't acquire the lock → cloud-init exits with `status: error`. The network configuration succeeded (proven by SSH working), but Ansible treated any non-zero rc as failure.

**Why the retries all failed:** The original task used `cloud-init status --wait`, which blocks internally until cloud-init finishes, then exits with rc=1. Each of the 20 retries ran immediately (cloud-init already done), got rc=1, and failed. The retries were pointless.

**Fix applied:**
```yaml
# Before: requires success (rc == 0)
command: cloud-init status --wait
until: cloud_init_status.rc == 0

# After: just requires cloud-init to be finished (done OR error)
command: cloud-init status
until: "'running' not in cloud_init_status.stdout"
failed_when: false
```

The apt lock handling is already managed by a dedicated Ansible task later in the playbook — cloud-init's upgrade failure is benign.

**Interview talking point:** `cloud-init status --wait` blocks until completion then returns the final status code. Using it with `retries` is pointless since every retry will return immediately with the same result once cloud-init is done. The correct pattern is to use `cloud-init status` (non-blocking) and retry until the output no longer contains "running".

---

### Incident #3 — Ingress EXTERNAL-IP Pending (MetalLB Pool vs DHCP IP Conflict)

**Date:** 2026-03-27
**Symptom:** `kubectl get svc -n ingress-nginx ingress-nginx-controller` showed `EXTERNAL-IP: <pending>` indefinitely. Accessing `blog.lennardjohn.org` and `grafana.lennardjohn.org` locally returned 404.

**Diagnostic commands run:**
```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
# NAME                       TYPE           CLUSTER-IP       EXTERNAL-IP   PORT(S)
# ingress-nginx-controller   LoadBalancer   10.106.231.233   <pending>     80:31280/TCP,443:31148/TCP

kubectl get ingress -A
# NAMESPACE    NAME       HOSTS                     ADDRESS        PORTS
# monitoring   grafana    grafana.lennardjohn.org   192.168.1.70   80
# wordpress    wordpress  blog.lennardjohn.org      192.168.1.70   80
```

**Root cause analysis:**

Two overlapping issues were found:

**Issue 1: INGRESS_IP outside MetalLB pool**
`.env` had `INGRESS_IP=192.168.1.70`. The MetalLB pool was `192.168.1.80-192.168.1.90`. The `cluster-networking.yml` Ansible playbook patches the ingress service with `loadBalancerIP: 192.168.1.70`, but MetalLB can only assign IPs within its configured pool. Since `.70` was outside the pool, MetalLB refused to assign it — hence `<pending>`. Fix: set `INGRESS_IP=192.168.1.80`.

**Issue 2: DHCP could assign MetalLB-range IPs to VMs**
VMs were using `ip=dhcp` in cloud-init. The router's DHCP pool covered the same range as MetalLB (`.80-.90`). On a rebuild, DHCP could assign `.80` to a VM, stealing the IP MetalLB needs for the ingress controller. Fix: switch VMs to static IPs outside the MetalLB range.

**Fix applied:**

`terraform/proxmox/main.tf`:
```hcl
# Before
ipconfig0 = "ip=dhcp"

# After (control plane)
ipconfig0 = "ip=${var.master_ip}/24,gw=${var.vm_gateway}"

# After (workers)
ipconfig0 = "ip=${var.worker_ips[each.key]}/24,gw=${var.vm_gateway}"
```

`terraform/proxmox/variables.tf` — added:
```hcl
variable "vm_gateway"  { default = "192.168.1.254" }
variable "master_ip"   { default = "192.168.1.70" }
variable "worker_ips"  { default = ["192.168.1.71", "192.168.1.72"] }
```

Final IP layout — no overlaps:
```
k8s-master-01:  192.168.1.70  (VM static)
k8s-worker-1:   192.168.1.71  (VM static)
k8s-worker-2:   192.168.1.72  (VM static)
MetalLB pool:   192.168.1.80–192.168.1.90
Ingress IP:     192.168.1.80
```

**Interview talking points:**
- MetalLB L2 mode requires the IP pool to be on the same subnet as the nodes but must not overlap with DHCP or static node IPs. Always plan IP ranges before deployment.
- `<pending>` on a LoadBalancer service means no cloud provider or MetalLB controller could satisfy the IP request — check the MetalLB controller logs (`kubectl logs -n metallb-system -l component=controller`) for the reason.
- Static IPs in cloud-init make infrastructure reproducible — critical for automated pipelines where DHCP assignments can change between runs.

---

## NOTE FOR CLAUDE — READ THIS BEFORE PROCESSING TRANSCRIPTS

### Source Reference Index Rule
Every new chat transcript processed must be scanned for:
- Any `image:` or `FROM` references (Docker images)
- Any `https://` URLs used in `kubectl apply -f`, `curl`, or `helm repo add`
- Any Terraform provider `source` and `version` entries
- Any external API endpoints called

For each one found, add a row to the relevant table in the **Source Reference Index** section. Include:
- The exact URL or image tag
- Where in the codebase it appears
- Why that specific version or source was chosen (if mentioned in the transcript)

If a URL or image was changed during the project (e.g. version bump or provider migration), document both the old and new value and the reason for the change.

When you process the chat history files added to this folder, apply the same standard used in the **Incident Reports** section below. For every error, debugging session, or architectural decision found in the transcripts:

1. **Create an Incident Report** (if it was a real error/debug session) with:
   - The exact symptom and error message
   - Every diagnostic command run and its output
   - Each hypothesis considered — including wrong ones
   - The root cause explanation (the "why", not just the "what")
   - The exact fix with before/after config snippets
   - An **Interview talking point** — what this demonstrates about your understanding

2. **Do not summarise** — if a config value, command, or error message appears in the transcript, include it verbatim in a code block.

3. **Wrong turns are valuable** — if a fix was tried and failed, document it. It shows systematic debugging methodology.

4. **Map everything to the Table of Contents** — each incident should also be referenced in the relevant ToC section (e.g. Incident #2 belongs under Section 5.1 WordPress and Section 3.2 Ansible probes).

---

## Awaiting Files

Drop the following into this folder (`Technical_book/`):

- Chat transcripts from other LLM sessions (any format — `.md`, `.txt`, `.pdf`)
- Any notes, error logs, or config snapshots you have saved

Once all files are present, the document will be populated in full following the structure below.

---

## Table of Contents

### Part 0: Career Context & Project Motivation
- 0.1 Why This Project Was Built (Platform Engineer job application target)
- 0.2 How to Use This Document (interview study guide, runbook, forensic record)
- 0.3 Mapping Skills to Job Descriptions (Terraform, K8s, Cloudflare, Observability)
- 0.4 Platform Engineer Narrative (deterministic, reproducible infrastructure over tool mastery)

### Part 1: Project Architecture & Decisions
- 1.1 Project Overview and Goals
- 1.2 Tool Selection Rationale (why each tool vs. alternatives)
- 1.3 Full Architecture Diagram (VM → K8s → Cloudflare → User)
- 1.4 Namespace Strategy (single cluster, multiple namespaces vs. separate clusters)
- 1.5 Pipeline Design (Docker Compose orchestrating Terraform → Ansible)

### Part 2: Infrastructure Layer (Proxmox + Terraform)
- 2.1 Proxmox Setup
  - 2.1.1 Selection Rationale (bare-metal hypervisor, homelab cost)
  - 2.1.2 Cloud-Init Template Creation (qm commands, boot-before-template rule)
  - 2.1.3 Serial Console vs VGA Console (debugging cloud images)
  - 2.1.4 Cloud-Init Lifecycle (first boot, machine-ID, DHCP ordering bugs)
  - 2.1.5 Autostart & Startup Order (onboot, startup order for cluster resilience)
  - 2.1.6 Failure Log (serial freeze, disk expansion, udev rules, template not booted)
  - 2.1.7 Security & Hardening
- 2.2 Terraform
  - 2.2.1 Selection Rationale
  - 2.2.2 Provider Configuration (Proxmox 3.0.2-rc07, Cloudflare >= 5.0)
  - 2.2.3 VM Provisioning (`main.tf` breakdown)
  - 2.2.4 Static IPs vs DHCP (why static, nameserver requirement, MetalLB conflict)
  - 2.2.5 SSH Key Handling (`pathexpand()`, `file()` execution context, case sensitivity)
  - 2.2.6 Variables & Secrets (`variables.tf`, `.env`, TF_VAR naming rules)
  - 2.2.7 Outputs (`outputs.tf`, `output.json`, atomic write pattern)
  - 2.2.8 Failure Log (provider version, 409 conflicts, TF_VAR hyphen, `~` not expanded)
  - 2.2.9 Security & Hardening

### Part 3: Kubernetes Cluster Bootstrap (Ansible + kubeadm)
- 3.1 Ansible
  - 3.1.1 Selection Rationale
  - 3.1.2 Playbook Structure and Execution Order (7 playbooks, why this order)
  - 3.1.3 Inventory Generation (`build_inventory.py`)
  - 3.1.4 apt Lock Management (unattended-upgrades, systemd timers, `dpkg --configure -a`)
  - 3.1.5 Failure Log (cloud-init status, blank apt error, DNS on static IPs, helm order, kube_join_command)
  - 3.1.6 Security & Hardening
- 3.2 kubeadm Cluster Initialisation
  - 3.2.1 Prerequisites (swap, kernel modules, sysctl, containerd, SystemdCgroup)
  - 3.2.2 Control Plane Init (kubeadm init, admin.conf, kubeconfig setup)
  - 3.2.3 Worker Join (token, hostvars, kube_join_command propagation)
  - 3.2.4 Calico CNI (pod CIDR, manifest patching)
  - 3.2.5 Failure Log (kubeconfig localhost:8080, crictl, containerd socket timing)

### Part 4: Kubernetes Platform Services
- 4.1 Helm (install order, idempotency with `creates:`, why installed in cluster-services)
- 4.2 NGINX Ingress Controller (baremetal variant, why not cloud provider manifest)
- 4.3 MetalLB
  - 4.3.1 L2 Mode, IPAddressPool, L2Advertisement
  - 4.3.2 IP Range Planning (no overlap with DHCP, node IPs, or MetalLB pool)
  - 4.3.3 Failure Log (webhook not ready, EXTERNAL-IP pending, IP conflict)
- 4.4 Local Path Provisioner (node filesystem storage, stale PVC data risk)
- 4.5 Metrics Server (`--kubelet-insecure-tls` patch for homelab)
- 4.6 cert-manager
  - 4.6.1 DNS-01 vs HTTP-01 (why DNS-01 with Cloudflare tunnel)
  - 4.6.2 ClusterIssuer Configuration
  - 4.6.3 Certificate Lifecycle (ACME, TXT records, secret storage)
  - 4.6.4 Failure Log

### Part 5: Application Deployments
- 5.1 WordPress + MariaDB
  - 5.1.1 Manifest Breakdown (Deployments, Services, PVCs, Ingress)
  - 5.1.2 Persistent Volumes & Stale Data Risk
  - 5.1.3 Secrets Injection (Ansible → K8s secret → env vars)
  - 5.1.4 Liveness vs Readiness Probes (TCP vs HTTP, timeoutSeconds, why they differ)
  - 5.1.5 MariaDB User Grants (`%` host, ClusterIP security boundary)
  - 5.1.6 Failure Log (HTTP 500, CrashLoopBackOff, stale PVC, host not allowed)
- 5.2 Prometheus + Grafana (kube-prometheus-stack)
  - 5.2.1 Resource Constraints on Small VMs (reduced requests for homelab)
  - 5.2.2 Helm Values Breakdown
  - 5.2.3 Grafana Ingress & Access
  - 5.2.4 Failure Log (pods pending, timeout too strict, resource limits)
- 5.3 Blog Architecture Decision (WordPress chosen over Hugo static site — rationale)

### Part 6: Cloudflare Integration
- 6.1 Zero Trust Tunnel
  - 6.1.1 Selection Rationale (vs port forwarding, vs VPN)
  - 6.1.2 Provider v4 → v5 Migration (what broke, what changed)
  - 6.1.3 Token Auth vs Credentials-File Auth
  - 6.1.4 Ingress Rules via API (`terraform_data`, why no local ConfigMap)
  - 6.1.5 Metrics Binding (`0.0.0.0` vs `127.0.0.1`, liveness probe requirement)
  - 6.1.6 Failure Log (409 conflict, 403 DNS, CrashLoopBackOff, rollout timeout)
- 6.2 DNS Records & TLS (CNAME to tunnel, cert-manager integration)

### Part 7: CI/CD Pipeline (Docker Compose)
- 7.1 Pipeline Design & Container Roles
- 7.2 Terraform Container (`run.sh`, atomic `output.json` write)
- 7.3 Ansible Container (`build_inventory.py`, playbook chain)
- 7.4 Secrets Flow (`.env` → containers → K8s secrets)
- 7.5 Failure Log (race conditions, `depends_on` limitations, SSH key injection)

### Part 8: Planned Additions
- 8.1 Argo CD (GitOps — pull-based vs push-based, Application CR)
- 8.2 GitHub Actions (CI — lint, test, image build on push)
- 8.3 Secrets Management (External Secrets Operator / Vault)
- 8.4 Alerting (Prometheus AlertManager rules)
- 8.5 NetworkPolicy for MariaDB (restrict to WordPress pod only)
- 8.6 Day-2 Operations (upgrades, backup, scaling)

### Part 9: Source Reference Index
- 9.1 Docker Base Images
- 9.2 Kubernetes Application Images
- 9.3 Raw Manifest URLs (kubectl apply -f)
- 9.4 Helm Chart Repositories
- 9.5 Terraform Providers
- 9.6 External APIs

### Appendix
- A. Full `.env` Template (sanitised)
- B. Deployment Checklist
- C. Teardown Procedure
- D. Complete Incident Log (all numbered incidents — quick reference)
- E. Interview Q&A Prep (one answer per incident)

---

---

## Part 0: Career Context & Project Motivation

---

### 0.1 Why This Project Was Built

This project was not built as a hobby. It was built deliberately to close the gap between "tutorial learner" and "hireable platform engineer" — and to serve as concrete, demonstrable evidence of platform engineering capability for job applications in New Zealand's tech sector.

**The author's background:**
Lennard John is an educator transitioning into DevOps/Platform Engineering. His most recent role was Head of Digital Technology in the New Zealand education sector. He brings cross-domain experience across education, business, technology leadership, and curriculum design.

**The career gap problem:**
Most DevOps/Platform Engineer job descriptions require commercial experience with tools like Terraform, Kubernetes, CI/CD pipelines, and observability stacks. Lennard had the systems-thinking and leadership background but needed a real, end-to-end project to demonstrate hands-on capability — not just tutorial completion.

**The solution:**
Build a production-style, fully automated platform from bare metal to running application — and document every decision, failure, and fix as if it were a real production incident. The result is a deterministic platform demonstrating core platform engineering patterns: IaC provisioning, automated cluster bootstrapping, and end-to-end deployment orchestration. Not just a running application — a repeatable, rebuildable system.

> "Not just a homelab. It is a production-style platform simulation. Demonstrates automation, resilience, architecture thinking."

> "Good move — this is exactly the kind of thing that lifts you from 'guy with a homelab' to 'hireable platform engineer.'"

> "I'm particularly interested in how platforms can reduce barriers — whether that's for students or developers — making systems more accessible and equitable."

---

### 0.2 Primary Job Target

**Role:** Platform Engineer
**Company:** Education Payroll (Crown entity, New Zealand)
**Salary band:** $108,000 – $162,000 (depending on experience and capability)
**Location:** Wellington, NZ (office-based, flexible after training period)
**Company context:** 200 employees, processes payroll for 102,000 New Zealand teachers, ~$7.7 billion per annum

**Key accountabilities from the job description (verbatim):**
- Designing, building and maintaining scalable platform infrastructure using an infrastructure-as-code approach (OpenTofu/Terraform) and Git-based workflows
- Operating and continuously improving an OpenShift container platform, including cluster upgrades, patching, troubleshooting and platform automation
- Enabling reliable delivery by supporting and evolving CI/CD pipelines (Tekton/OpenShift Pipelines, Jenkins) and GitOps workflows (Argo CD/OpenShift GitOps)
- Supporting secure, standardised platform operations including policy-as-code (OpenShift ACM policies), operators, service mesh and secrets management (HashiCorp Vault)
- After-hours on-call support on a rostered basis

**Why this role specifically:**
The job description maps to the same foundational skills this homelab demonstrates — IaC, container orchestration, CI/CD pipeline design, and observability. The project was designed and extended with this role in mind. There are intentional gaps (OpenShift vs kubeadm, Vault vs .env secrets) — these are acknowledged and on the roadmap (see Section 0.3b).

---

### 0.3 Mapping Homelab Skills to Job Requirements

#### 0.3a Current Homelab Coverage

| Job Requirement | Status | Homelab Demonstration |
|---|---|---|
| IaC with Terraform + Git workflows | ✅ Done | Terraform provisions all VMs, Cloudflare resources, DNS records. All config in Git. |
| Container platform operations | ✅ Done | 3-node kubeadm cluster on Proxmox. Calico, MetalLB, NGINX Ingress. |
| CI/CD pipeline design | ✅ Done | Docker Compose: Terraform → Python inventory → Ansible → Kubernetes |
| Observability | ✅ Done | Prometheus + Grafana via Helm (kube-prometheus-stack) |
| Platform reliability & incident response | ✅ Done | 9+ documented incidents with root cause analysis and fixes |
| Secrets injection | 🟡 Partial | `.env` → K8s secrets via Ansible. Vault not yet implemented. |
| GitOps | 🟡 Partial | Argo CD planned — currently Ansible push-based |
| Policy-as-code | ❌ Planned | NetworkPolicy (MariaDB restriction) and OPA on roadmap |

#### 0.3b Intentional Gaps & Roadmap

The homelab uses kubeadm (not OpenShift), Ansible push (not Tekton/Argo CD), and `.env` secrets (not Vault). These are known gaps — not oversights. The bridging language for interview:

| Role Requires | Homelab Has | Bridge Statement |
|---|---|---|
| OpenShift container platform | kubeadm K8s cluster | "I understand the Kubernetes foundation that OpenShift is built on — operators, CRDs, RBAC, ingress. OpenShift adds enterprise tooling on top of that." |
| Tekton / Jenkins pipelines | Docker Compose + Ansible | "My pipeline (Terraform → Ansible → kubectl apply) is the conceptual precursor to GitOps tools like Tekton. The pattern is the same — declarative, automated, auditable." |
| HashiCorp Vault | .env → K8s secrets | "I understand the secrets lifecycle — creation, injection, rotation. Vault adds centralised management and audit trails, which I'm implementing next." |
| Argo CD / OpenShift GitOps | Ansible push-based deploy | "I'm currently push-based. Argo CD is on my roadmap — it's the pull-based evolution of what I'm already doing." |

#### 0.3c Feature Translation (Reframing for Interview)

Always translate tool names to outcomes:

| What you built | How to say it |
|---|---|
| Docker Compose pipeline | "CI/CD pipeline foundation" |
| Ansible playbooks | "Configuration management and automated provisioning" |
| kubectl apply in Ansible | "GitOps precursor — declarative, version-controlled deployment" |
| `.env` secrets | "Secrets lifecycle management — injection, scoping, separation from code" |
| Grafana dashboards | "Observability layer with real-time platform visibility" |

---

### 0.4 Platform Engineer Narrative

The key narrative is: **platform, not just tools**.

> "I didn't just build a Kubernetes cluster — I built a repeatable platform. The entire environment can be recreated end-to-end using Terraform, Ansible, and Docker Compose."

> "I treat my homelab like production — everything is automated, version-controlled, and rebuildable from scratch."

> "My focus isn't just getting things running — it's making them reliable, reproducible, and easy to maintain for others."

**The secret weapon — teaching background:**
The author's teaching background is reframed as a platform engineering advantage, not a liability:
- Teachers break down complex systems clearly → useful for documentation, runbooks, and cross-team communication
- Education leadership → stakeholder management, systems thinking, scalability
- "As a teacher, I've developed the ability to break down complex systems — which actually helps when documenting and designing platforms."
- "I naturally think about systems in terms of scalability and user experience — not just technical implementation."

#### 0.4a The Equity Angle (NZ Context — Secret Weapon)

For Crown entity roles in New Zealand (like Education Payroll), values alignment matters as much as technical fit. Use this framing:

> "I'm particularly interested in how platforms can reduce barriers — whether that's for students or developers — making systems more accessible and equitable."

This connects platform engineering directly to the author's education background and signals Te Tiriti / equity awareness — a genuine differentiator for NZ public sector roles.

**Addressing the "no commercial experience" objection:**
> "That's true — but I've deliberately built real-world systems to bridge that gap. I'm not coming in cold — I've already worked through many of the same challenges around automation, networking, and reliability, just in my own environment."

> "I may not have done this in a commercial environment yet, but I've built and troubleshot the same kinds of systems you'd expect in one."

> "I'm still early in my DevOps journey, but I've deliberately built real systems end-to-end — not just followed tutorials."

**Final positioning statement:**
> "What I bring is a combination of hands-on platform engineering skills and a systems-thinking mindset from my leadership background. I haven't just learned tools — I've built a full platform end-to-end, automated it, broken it, and improved it. I'm now looking to apply that in a real environment at scale."

---

### 0.5 Interview Strategy

**Pre-application outreach (LinkedIn/email to hiring manager):**

Reach out before applying with a short message (5–7 lines max):

```
Kia ora,

I saw the Platform Engineer role on Seek and thought I'd reach out.

I've been building a Kubernetes setup using Terraform and Ansible in my own lab,
so it looks quite similar to what I've been working on.

Just curious, is the team more focused right now on building out the platform,
or improving what's already there?

Thanks,
Lennard
```

**Strategy:** Send message → Get reply → Apply within 24–48 hours → Mention in cover letter: "After speaking with [Name]..."

**In interview — anchor everything to the homelab:**
Use phrases like: "In my platform...", "In my setup...", "What I designed was..."
Always translate: Tool → Outcome, Tech → Business value.

**Key signature lines for interview:**

- *On infrastructure:* "I use Terraform with the Proxmox provider to provision infrastructure, and I structure outputs so they feed directly into configuration management."
- *On automation:* "I built a pipeline where Terraform outputs VM data, a Python script generates dynamic inventory, and Ansible bootstraps Kubernetes — all orchestrated through Docker Compose."
- *On networking:* "I use Cloudflare Tunnel and Zero Trust to securely expose services without opening ports — which mirrors how modern edge-first architectures work."
- *On reliability:* "In distributed systems, reliability comes from resilience — not timing. Kubernetes converges over time — you design for that, not against it."
- *On observability:* "I've integrated Prometheus and Grafana so I can actually see what's happening inside the cluster."
- *On OpenShift bridge:* "I understand the Kubernetes foundation that OpenShift is built on. OpenShift adds enterprise tooling on top — the operational patterns translate directly."

#### 0.5a Follow-up Strategy (After Hiring Manager Replies)

When the hiring manager responds to your outreach, listen to their answer and reflect it back:

**If they say "building out the platform":**
> "That's great — I've been doing a lot of that in my own setup, especially around automating infrastructure and bootstrapping Kubernetes from scratch."

**If they say "improving and evolving what's already there":**
> "That's interesting — I've recently been focusing more on reliability and observability in my own environment, making sure the platform is maintainable and visible."

Then apply within 24–48 hours and mention in your cover letter: *"After speaking with [Name], I understand the team is focused on [X]..."*

#### 0.5b Interview Closing Lines

Use these to close strong without overselling:

**Growth mindset:**
> "I'm still early in my DevOps journey, but I've deliberately built real systems end-to-end — not just followed tutorials."

**Confidence without arrogance:**
> "I may not have done this in a commercial environment yet, but I've built and troubleshot the same kinds of systems you'd expect in one."

**Final punch:**
> "What I'm really looking for is a team where I can take what I've built independently and apply it at scale."

---

### 0.6 Alternative Positioning

This homelab is not only relevant to Platform Engineer roles. The same project, reframed:

| Target Role | Key Reframe |
|---|---|
| **DevOps Engineer** | Emphasise the pipeline (Terraform → Ansible → K8s), automation patterns, and incident resolution |
| **Solution Architect** | Emphasise architecture decisions (why Cloudflare over VPN, why MetalLB, why cert-manager DNS-01), integration design, and trade-off reasoning |
| **Cloud Engineer** | Emphasise that cloud principles (IaC, immutable infra, declarative config) were applied on-prem — same patterns, different substrate |
| **Infrastructure Engineer** | Emphasise bare-metal provisioning, networking (Calico, MetalLB), storage (local-path-provisioner), and OS-level configuration (kubeadm, containerd) |

For Solution Architect roles specifically, reframe language:
- "Built CI pipelines" → "Designed delivery pipelines aligned to enterprise standards"
- "Kubernetes networking" → "Designed intra-cluster routing and service mesh foundations"
- "Cloudflare Tunnel" → "Designed edge-first secure access architecture without inbound exposure"

---

## Source Reference Index

Every external dependency used in this project — where it comes from, what version, and why.

---

### Docker Base Images

| Image | Source | Used In |
|---|---|---|
| `hashicorp/terraform:1.14` | [Docker Hub — HashiCorp official](https://hub.docker.com/r/hashicorp/terraform) | `docker/terraform/Dockerfile` |
| `python:3.12.0-slim` | [Docker Hub — Python official](https://hub.docker.com/_/python) | `docker/ansible/Dockerfile` |

**Why these:**
- `hashicorp/terraform` — official image from HashiCorp, pinned to `1.14` for reproducibility
- `python:3.12.0-slim` — slim variant reduces image size; Python needed for Ansible and `build_inventory.py`

---

### Kubernetes Application Images

| Image | Registry | Used In |
|---|---|---|
| `cloudflare/cloudflared:2024.10.0` | [Docker Hub — Cloudflare official](https://hub.docker.com/r/cloudflare/cloudflared) | `kubernetes/cloudflared/deployment.yaml` |
| `mariadb:11` | [Docker Hub — MariaDB official](https://hub.docker.com/_/mariadb) | `kubernetes/wordpress/mariadb.yaml` |
| `wordpress:php8.2-apache` | [Docker Hub — WordPress official](https://hub.docker.com/_/wordpress) | `kubernetes/wordpress/wordpress.yaml` |

**Why these:**
- `cloudflared:2024.10.0` — pinned to avoid breaking changes; Cloudflare releases frequently
- `mariadb:11` — major version pin; MariaDB 11 is the current LTS release
- `wordpress:php8.2-apache` — Apache variant chosen over FPM for simplicity (built-in web server); PHP 8.2 is current stable

---

### Raw Manifest URLs (kubectl apply -f)

| Component | Version | URL | Source Org |
|---|---|---|---|
| NGINX Ingress Controller | `controller-v1.10.1` | `https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/baremetal/deploy.yaml` | kubernetes/ingress-nginx |
| MetalLB | `v0.14.5` | `https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml` | metallb/metallb |
| Local Path Provisioner | `v0.0.35` | `https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.35/deploy/local-path-storage.yaml` | rancher/local-path-provisioner |
| Metrics Server | `v0.8.1` | `https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.1/components.yaml` | kubernetes-sigs/metrics-server |
| Calico CNI | `v3.27.0` | `https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml` | projectcalico/calico |

**Why baremetal for NGINX Ingress:**
The standard cloud provider deploy assumes a cloud LoadBalancer exists. The `baremetal` variant deploys NGINX as a NodePort service, which MetalLB then promotes to a LoadBalancer with a real IP.

**Why these versions:**
All versions are pinned explicitly to avoid unexpected breaking changes on re-deploy. Using `latest` or unpinned refs would make the build non-reproducible.

---

### Helm Chart Repositories

| Chart | Repo Name | Repo URL | Used For |
|---|---|---|---|
| `prometheus-community/kube-prometheus-stack` | `prometheus-community` | `https://prometheus-community.github.io/helm-charts` | Prometheus + Grafana + AlertManager |
| `jetstack/cert-manager` | `jetstack` | `https://charts.jetstack.io` | TLS certificate management |

**Helm itself:**
Installed via the official install script: `https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3`

---

### Terraform Providers

| Provider | Registry | Version |
|---|---|---|
| `Telmate/proxmox` | [registry.terraform.io/providers/Telmate/proxmox](https://registry.terraform.io/providers/Telmate/proxmox) | `3.0.2-rc07` |
| `cloudflare/cloudflare` | [registry.terraform.io/providers/cloudflare/cloudflare](https://registry.terraform.io/providers/cloudflare/cloudflare) | `>= 5.0` |

**Why Telmate/proxmox `3.0.2-rc07`:**
This is a release candidate but is the most stable version supporting the Proxmox API v8 features used (cloud-init, full_clone, guest agent IP reporting). The official v2.x releases do not support all required fields.

**Why Cloudflare `>= 5.0`:**
Provider v5 renamed resources (`cloudflare_tunnel` → `cloudflare_zero_trust_tunnel_cloudflared`, `cloudflare_record` → `cloudflare_dns_record`). Pinning to `>= 5.0` ensures we use the stable v5 API. The tunnel configuration resource was removed in v5 — ingress rules are now managed via the Cloudflare API directly using a `terraform_data` local-exec.

---

### External APIs

| API | Endpoint | Used For | Auth |
|---|---|---|---|
| Cloudflare API | `https://api.cloudflare.com/client/v4/accounts/{id}/cfd_tunnel/{id}/token` | Fetch tunnel token in Ansible | Bearer token (`TF_VAR_cloudflare_api_token`) |
| Cloudflare API | `https://api.cloudflare.com/client/v4/accounts/{id}/cfd_tunnel/{id}/configurations` | Configure tunnel ingress rules in Terraform | Bearer token (same) |
| Let's Encrypt ACME | `https://acme-v02.api.letsencrypt.org/directory` | Issue TLS certificates via cert-manager | DNS-01 via Cloudflare API |
| Kubernetes APT repo | `https://pkgs.k8s.io/core:/stable:/v1.30/deb/` | Install kubelet, kubeadm, kubectl | Signed GPG key |

---

### Appendix
- A. Full `.env` Template (sanitised)
- A. Deployment Checklist
- B. Teardown Procedure
- C. Glossary of Tools & Terms
- D. Interview Q&A Prep

---

*Waiting for additional transcript files. Sections below are pre-populated from live debugging sessions.*

---

## Incident Reports

These are real debugging sessions, documented in full — commands run, output observed, root cause identified, and fix applied. These are the most interview-valuable sections of this document.

---

### Incident #1 — cloudflared CrashLoopBackOff (Metrics Server Not Reachable)

**Date:** 2026-03-26
**Symptom:** `kubectl rollout status deployment/cloudflared -n cloudflared --timeout=120s` timed out. Ansible reported non-zero return code after 2 minutes.

**Initial observation:**
```
Waiting for deployment "cloudflared" rollout to finish: 0 out of 2 new replicas have been updated...
Waiting for deployment "cloudflared" rollout to finish: 0 of 2 updated replicas are available...
```

**Diagnostic commands run:**
```bash
kubectl get pods -n cloudflared
# NAME                           READY   STATUS             RESTARTS
# cloudflared-64cccf758c-jrcp6   0/1     CrashLoopBackOff   5

kubectl describe pods -n cloudflared
# Warning Unhealthy: Liveness probe failed:
#   Get "http://10.96.140.14:2000/ready": dial tcp 10.96.140.14:2000: connect: connection refused

kubectl logs -n cloudflared -l app=cloudflared
# INF Starting metrics server on 127.0.0.1:44433/metrics
# INF Registered tunnel connection connIndex=0 ... location=chc01 protocol=quic
# INF Updated to new configuration config="{\"ingress\":[{\"hostname\":\"blog.lennardjohn.org\"...
```

**Root cause analysis:**

The logs revealed two critical facts:
1. The tunnel was **actually working** — 4 connections registered to Cloudflare edge, ingress rules loaded correctly.
2. The metrics server was binding to `127.0.0.1:44433` — a random port on the loopback interface.

The liveness probe was configured as:
```yaml
livenessProbe:
  httpGet:
    path: /ready
    port: 2000
```

The kubelet sends this probe from outside the container to the pod IP (e.g. `10.96.140.14`). But the metrics server was only listening on `127.0.0.1` (loopback, inside the container) on a random port — not `0.0.0.0:2000`. The probe could never reach it.

**Why the default behavior:** cloudflared's `--metrics` flag defaults to a random available port on localhost. Without explicitly binding it, there is no way to probe it from outside the container.

**Fix applied:**
```yaml
# kubernetes/cloudflared/deployment.yaml
args:
  - tunnel
  - --no-autoupdate
  - --metrics          # added
  - 0.0.0.0:2000       # added — bind to all interfaces on fixed port
  - run
  - --token
  - $(TUNNEL_TOKEN)
```

**Interview talking point:** This is a classic container networking gotcha. Processes binding to `127.0.0.1` are not reachable by Kubernetes health probes because the kubelet hits the pod IP, not the container's loopback. Always bind metrics/health endpoints to `0.0.0.0` in containerised workloads.

---

### Incident #2 — WordPress CrashLoopBackOff (Probe Timeout on Fresh Deploy)

**Date:** 2026-03-26
**Symptom:** WordPress pod in CrashLoopBackOff, never became Ready. Grafana (same cluster, same tunnel) was accessible — confirming the issue was WordPress-specific.

**Diagnostic commands run:**
```bash
kubectl get pods -n wordpress
# NAME                        READY   STATUS             RESTARTS
# mariadb-57b6fc8774-75blr    1/1     Running            0
# wordpress-5d458d869-7bxkp   0/1     CrashLoopBackOff   9

kubectl describe pod wordpress -n wordpress
# Warning Unhealthy: Liveness probe failed: HTTP probe failed with statuscode: 500
# Warning Unhealthy: Readiness probe failed:
#   Get "http://10.96.230.8:80/wp-admin/install.php": context deadline exceeded
# Normal  Killing: Container wordpress failed liveness probe, will be restarted
```

**Initial hypothesis — wrong DB credentials:**

The probe was redirecting to `/wp-admin/install.php`, which WordPress only shows when it cannot connect to the database. Checked secret values:

```bash
kubectl get secret wordpress-secrets -n wordpress \
  -o jsonpath='{.data.mariadb-user}' | base64 -d && echo
# wordpress

kubectl get secret wordpress-secrets -n wordpress \
  -o jsonpath='{.data.mariadb-database}' | base64 -d && echo
# wordpress
```

Values looked correct. Tested the actual DB connection:

```bash
kubectl exec -n wordpress deployment/mariadb -- \
  mariadb -u wordpress \
  -p$(kubectl get secret wordpress-secrets -n wordpress \
    -o jsonpath='{.data.mariadb-password}' | base64 -d) \
  -e "SHOW DATABASES;"
# Database
# information_schema
# wordpress
```

**DB connection worked.** Credentials were correct. `wordpress` database existed.

**Revised diagnosis — two separate probe bugs:**

**Bug 1: HTTP liveness probe returning 500 on startup**

On first boot, WordPress hits `/` before it finishes initialising. If the DB connection isn't ready yet, it returns HTTP 500. The liveness probe (`failureThreshold: 3, periodSeconds: 20`) sees 3 × 500 responses and kills the pod — before WordPress ever stabilises.

**Bug 2: Readiness probe timeout on redirect chain**

The readiness probe hits `/`. On a fresh WordPress install (no `wp_*` tables yet), WordPress redirects `302 → /wp-admin/install.php`. Kubernetes follows redirects on httpGet probes. The install page performs DB queries before rendering, taking >1 second. Default `timeoutSeconds: 1` causes `context deadline exceeded`. Probe fails, pod never becomes Ready.

**Note:** MariaDB "Aborted connection" warnings in logs were a red herring — these are the TCP readiness probe connections being closed after the port check, which is normal.

**Fix applied:**
```yaml
# kubernetes/wordpress/wordpress.yaml

# Before: HTTP liveness killing pod on DB errors during startup
livenessProbe:
  httpGet:
    path: /
    port: 80
  initialDelaySeconds: 60

# After: TCP liveness only checks Apache is running — no DB involvement
livenessProbe:
  tcpSocket:
    port: 80
  initialDelaySeconds: 60
  periodSeconds: 20
  failureThreshold: 3

# Before: 1 second timeout (default), fails on slow install page
readinessProbe:
  httpGet:
    path: /
    port: 80
  initialDelaySeconds: 30

# After: 5 second timeout accommodates install page DB queries
readinessProbe:
  httpGet:
    path: /
    port: 80
  initialDelaySeconds: 30
  timeoutSeconds: 5      # increased from default 1
  periodSeconds: 10
  failureThreshold: 3
```

**Interview talking points:**
- Liveness and readiness probes serve different purposes: liveness checks if the process is alive (restart if not), readiness checks if it can serve traffic (remove from load balancer if not). Using HTTP for liveness on a DB-dependent app creates a false dependency — Apache can be healthy even when the DB is unreachable.
- `timeoutSeconds` defaults to 1 second, which is aggressive for anything that does I/O. Always set it explicitly.
- On a fresh WordPress deploy, the install wizard is expected — it means DB credentials are correct but WordPress hasn't been configured yet. Navigate to `/wp-admin/install.php` to complete setup.
