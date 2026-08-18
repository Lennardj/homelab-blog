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

---

## Feature — AlertManager Email Alerts and Prometheus Rules

### What was built

Added custom Prometheus alerting rules and configured AlertManager to send email notifications via Gmail SMTP. Alerts are also visible in Grafana natively.

### Alert rules added to `kubernetes/monitoring/values.yaml`

| Alert | Fires when | Severity |
|---|---|---|
| PodCrashLooping | Pod restarts in last 10 min | critical |
| PodNotReady | Pod not ready for 5 min | warning |
| DeploymentReplicasMismatch | Desired ≠ ready replicas for 10 min | warning |
| NodeNotReady | Node down for 2 min | critical |
| NodeHighMemory | Memory > 85% for 5 min | warning |
| NodeHighCPU | CPU > 85% for 5 min | warning |
| NodeDiskPressure | Disk > 85% for 5 min | warning |

### How it works

The rules are defined under `additionalPrometheusRulesMap` in the Helm values file. Helm creates `PrometheusRule` CRDs from these on install. Prometheus evaluates the PromQL expressions on its scrape interval. When a condition holds for the `for` duration, it fires the alert to AlertManager.

AlertManager groups alerts by `alertname` and `namespace`, waits 30s to batch, then sends to the email receiver. `send_resolved: true` sends a follow-up email when the alert clears.

### Email configuration

- SMTP: Gmail (`smtp.gmail.com:587`) with a Gmail App Password
- `smtp_auth_password` is not stored in `values.yaml` — Ansible injects it via `--set alertmanager.config.global.smtp_auth_password={{ lookup('env', 'ALERTMANAGER_SMTP_PASSWORD') }}`
- Same pattern as `GRAFANA_ADMIN_PASSWORD` — secret in `.env`, injected at deploy time, never in Git

### Grafana integration

No extra configuration needed. Grafana's built-in Prometheus data source automatically discovers all firing alerts. Navigate to **Alerting → Alert rules** in Grafana to see them.

### Interview talking point

AlertManager is the notification engine — Prometheus evaluates the rules and fires to AlertManager, which handles grouping, deduplication, silencing, and routing. This separation means you can change who gets notified (email, Slack, PagerDuty) without touching the alert rules themselves. The `for` duration prevents flapping — a brief CPU spike won't fire an alert, only sustained conditions. The `group_wait` and `group_interval` settings batch related alerts into a single email instead of spamming one per pod.

---

## Feature — GitHub Actions CI/CD (Self-Hosted Runner)

### What was built

A GitHub Actions workflow that triggers `docker compose up` automatically on push, replacing the manual step of running it from a laptop.

**Trigger:** push to `main` on paths `terraform/**` or `ansible/**`
**Runner:** `runner-01` — a permanent VM on Proxmox, outside Terraform management
**Workflow file:** `.github/workflows/deploy.yml`

### Why self-hosted runner on Proxmox

GitHub-hosted runners are ephemeral cloud VMs. They have no access to the home LAN (`192.168.1.0/24`). Terraform needs to reach Proxmox at `192.168.1.174` and Ansible needs SSH access to `192.168.1.70-72`. A self-hosted runner on Proxmox has direct LAN access and requires no Tailscale tunnel or secret injection into GitHub.

### Key design decisions

**Secrets stay on the runner VM, not in GitHub.**
`.env` is stored at `/home/lennard/.env` on the runner VM (IP: 192.168.1.73). The workflow copies it into the checked-out repo directory at the start of each job. GitHub never receives secret values.

**Runner is a permanent VM, not Terraform-managed.**
The K8s VMs (master + workers) are torn down and recreated by Terraform. The runner VM must survive `terraform destroy` — so it is created manually in Proxmox and never referenced in Terraform code.

**`SSH_KEY_DIR` path changes from Windows to Linux.**
On the laptop: `SSH_KEY_DIR=C:/Users/User/.ssh`
On the runner VM: `SSH_KEY_DIR=/home/lennard/.ssh`
This is the only `.env` change needed to move from laptop to CI.

**`TF_STATE_DIR` is set in the workflow, not in `.env`.**
If `TF_STATE_DIR` were in `.env`, the synced `.env` would contain a Linux path that breaks the laptop. Instead, the workflow sets `TF_STATE_DIR=/home/lennard/.terraform-state` as an environment variable on the `docker compose up` step only. On the laptop, the default `./terraform/proxmox` kicks in — same dir as the working directory, so no copy happens.

**`concurrency: group: deploy`** prevents two workflow runs executing at the same time if commits are pushed in quick succession. The second run queues rather than cancelling.

**Cleanup runs on `if: always()`** — even if Terraform or Ansible fails. Includes:
- `docker compose down --remove-orphans` — stops and removes containers
- `sudo rm -rf terraform/proxmox/.terraform` — removes root-owned provider files
- `docker system prune --all --force --volumes` — removes images to prevent disk bloat (bind mounts like `/home/lennard/.terraform-state/` are not Docker volumes, so they are safe from prune)

### Runner as systemd service

```bash
cd ~/actions-runner
sudo ./svc.sh install
sudo ./svc.sh start
```

Registers the runner as a systemd service. Starts automatically on boot — no need to manually run `./run.sh`.

### Syncing `.env` from laptop to runner VM

```powershell
.\scripts\sync-env.ps1
```

Runs `scp .env lennard@192.168.1.73:/home/lennard/.env`. Run manually after any `.env` change — not automated, because syncing secrets on a schedule is a security risk.

### Interview talking point

A self-hosted runner is the correct choice when your pipeline needs access to private infrastructure. It trades the convenience of GitHub-hosted runners (zero maintenance, fresh environment every run) for network locality and secret isolation. The runner VM is the only machine that holds credentials — rotate `.env` on the VM and the next CI run picks up the new values automatically.

---

## Incident #19 — CI: Root-owned `.terraform/` blocks GitHub Actions checkout

**Symptom:** Workflow fails at checkout step with `Error: EACCES: permission denied, rmdir '.terraform/providers'`.

**Root cause:** Docker Compose runs the Terraform container as root. Terraform downloads providers into `.terraform/providers/` — these files are owned by `root:root`. The GitHub Actions checkout step runs `git clean -ffdx` to reset the workspace, but the runner runs as `lennard` and can't delete root-owned files.

**Fix:** Added pre-checkout step `sudo rm -rf $GITHUB_WORKSPACE/.terraform` and post-cleanup `sudo rm -rf terraform/proxmox/.terraform` to the workflow. Requires passwordless `sudo` on the runner VM.

**Interview talking point:** Container filesystem ownership mismatch is common in CI/CD. Docker containers default to root unless a `USER` directive is specified. When containers write to bind-mounted host directories, the files inherit root ownership — causing permission issues for the non-root CI agent. The fix is either: set a matching UID in the container, or clean with `sudo` in the CI workflow.

---

## Incident #20 — CI: `sudo: a password is required` in workflow

**Symptom:** Pre-checkout `sudo rm -rf` fails with `sudo: a terminal is required to read the password`.

**Root cause:** The `lennard` user had `NOPASSWD: ALL` in `/etc/sudoers`, but the `%sudo` group rule appeared after it. Since `lennard` is in the `sudo` group, the group rule overrode the user-specific `NOPASSWD` line — sudoers rules are evaluated in order and the last match wins.

**Fix:** Created a drop-in file `/etc/sudoers.d/lennard` containing `lennard ALL=(ALL) NOPASSWD: ALL`. Drop-in files in `/etc/sudoers.d/` are included via `@includedir` at the very end of the main sudoers file, so they always take final precedence.

**Interview talking point:** Sudoers evaluation is order-sensitive — the last matching rule wins. Group rules (`%sudo`) can override user-specific rules if they appear later. Drop-in files in `/etc/sudoers.d/` are the standard way to add per-user overrides because they are processed last and don't require editing the main file.

---

## Incident #21 — CI: Cloudflare DNS `already exists` on every run

**Symptom:** `400 Bad Request: An A, AAAA, or CNAME record with that host already exists` for all DNS records (blog, grafana, argocd, landing).

**Root cause:** `terraform.tfstate` was not persisted between CI runs. The cleanup step deleted Docker volumes and `git clean` wiped the working directory. Without state, Terraform tried to CREATE every resource on each run. Proxmox has `force_create = true` to handle this, but Cloudflare has no equivalent — attempting to create a duplicate DNS record is a hard error.

**Diagnostic steps:**
1. Confirmed DNS records existed in Cloudflare dashboard
2. Confirmed `terraform.tfstate` was absent in the `_work/` directory at job start
3. Traced deletion to `docker compose down --volumes` + checkout `git clean`

**Fix:** Persistent state via bind mount:
- Created `/home/lennard/.terraform-state/` on the runner VM
- `docker-compose.yaml` mounts `${TF_STATE_DIR:-./terraform/proxmox}:/tfstate`
- `docker/terraform/run.sh` copies state from `/tfstate/` before `terraform init` and back after `terraform apply`
- `TF_STATE_DIR=/home/lennard/.terraform-state` is set in the workflow `env:` block, not in `.env` (would break Windows laptop)
- Bind mount survives `docker system prune --volumes` (prune only removes Docker named volumes)

**Interview talking point:** Terraform state is the single source of truth for what Terraform manages. Without it, Terraform treats every run as a greenfield deployment. In production, state is stored in a remote backend (S3, Consul, Terraform Cloud). For a homelab CI setup, a persistent bind mount on the runner VM is a lightweight alternative. The key insight is that state must outlive the CI job — anything inside the container or Docker volume is ephemeral by design.

---

## Incident #22 — CI: `cp: same file` error in Terraform `run.sh`

**Symptom:** `cp: 'terraform.tfstate' and '/tfstate/terraform.tfstate' are the same file` — Terraform container exits with code 1, Ansible times out waiting for `output.json`.

**Root cause:** On the laptop, `TF_STATE_DIR` is not set. The `docker-compose.yaml` default `${TF_STATE_DIR:-./terraform/proxmox}` maps `./terraform/proxmox` to `/tfstate` in the container. But Terraform's working directory is also `/work/terraform/proxmox`. Since the host path is bind-mounted both as `/work/terraform/proxmox` (via `./:/work`) and as `/tfstate`, they point to the same directory. `cp terraform.tfstate /tfstate/terraform.tfstate` attempts to copy a file onto itself.

**Fix:** Added a same-file guard in `run.sh`:
```sh
if ! [ /tfstate/terraform.tfstate -ef terraform.tfstate ]; then
  cp terraform.tfstate /tfstate/terraform.tfstate
fi
```
The `-ef` test checks if two paths refer to the same inode — returns true on the laptop (same dir), false on the runner (separate bind mount).

**Interview talking point:** Bind mounts can create surprising overlaps when the same host directory is mounted at multiple container paths. The `-ef` shell test (POSIX) checks inode identity, not string equality — it correctly handles symlinks, bind mounts, and relative paths. This is a common pattern when a script needs to work across different mount configurations.

---

## Incident #23 — Grafana 503 from nginx: Helm release vanished from `monitoring` namespace

**Symptom:** `https://grafana.lennardjohn.org` returned `503 Service Temporarily Unavailable` from nginx. Pods appeared to be running in a stale `command_output.txt` from earlier, but the live cluster state was different.

**Diagnostic steps:**

1. `kubectl describe ingress -n monitoring grafana` showed:
   ```
   kube-prometheus-stack-grafana:80 (<error: endpoints "kube-prometheus-stack-grafana" not found>)
   ```
2. `kubectl get svc -n monitoring kube-prometheus-stack-grafana` → `NotFound`
3. `kubectl get pods,svc -n monitoring` → `No resources found in monitoring namespace.`
4. Verified WordPress PVCs (`kubectl get pvc -n wordpress`) were still `Bound` — confirmed data was safe before reinstalling.

**Root cause:** The entire `kube-prometheus-stack` Helm release had been removed from the `monitoring` namespace. The Ingress and Namespace objects survived because they're git-tracked via `kubernetes/monitoring/kustomization.yaml` (and reconciled by ArgoCD), but the Helm-managed resources (Deployment, Service, PVC, ConfigMaps) are **not** in git — they live only in Helm's release history. When the release was gone, the Service disappeared, nginx-ingress had no backend endpoints, and every request returned 503.

The triggering event was likely a failed `helm upgrade` during an earlier attempt at tuning memory/alerts (recent commits: `remove additionalPrometheusRulesMap to reduce noise`, `increase the memory on node`). ArgoCD was ruled out as the culprit: its `monitoring` Application only tracks `namespace.yaml` + `grafana-ingress.yaml`, and Helm-managed resources don't carry ArgoCD tracking labels, so auto-prune wouldn't touch them.

**Fix:** Reinstalled the Helm release directly from the master node — no Ansible, no GitHub runner needed, since `helm` and `kubectl` are already on the master:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --values /tmp/values.yaml \
  --set grafana.adminPassword='***' \
  --set alertmanager.config.global.smtp_auth_password='***'
```

Command matches `ansible/playbook/deploy-monitoring.yml:36-47` exactly — same chart, same repo, same namespace, same values, same `--set` flags. Skipping the Ansible wrapper is safe because:
- The kustomize step (`kubectl apply -k`) that the playbook runs first only creates `namespace.yaml` + `grafana-ingress.yaml`, both of which already existed.
- The ArgoCD Application registration at the end of the playbook is idempotent — the Application already existed.

**Verification:**

```
curl -vk https://grafana.lennardjohn.org
< HTTP/1.1 302 Found
< Location: /login
```

302 → `/login` is Grafana's healthy redirect to its login page. The browser still showed 503 initially because browsers cache error responses — `Ctrl+Shift+R` (hard refresh) or an incognito window returned the login page immediately.

**Interview talking points:**

1. **GitOps only protects what's in git.** ArgoCD rebuilt the namespace and ingress because those are declared in `kubernetes/monitoring/`. It could not rebuild the Helm release because Helm-managed resources are rendered at install time, not stored in git. This is a real blind spot in hybrid GitOps+Helm setups — mitigations include: (a) `argocd-helm` plugin that lets ArgoCD own the Helm install, (b) pre-rendering Helm charts into static manifests and committing those, or (c) accepting that Helm-managed apps need a separate bootstrap/recovery path.
2. **Ingress 503 diagnostic path.** When nginx returns 503, start with the backend: `kubectl describe ingress` tells you the service name and whether endpoints exist. Empty endpoints almost always mean the Service's label selector doesn't match any pods — either pods are gone, pods have wrong labels, or readiness probes are failing. "Endpoints not found" (a different error) means the Service object itself is missing.
3. **Stale tool output can mislead diagnosis.** The initial `command_output.txt` showed Grafana pods running, but that file was from an earlier session. The ingress description from the live cluster showed the actual state. Rule: when state looks inconsistent, trust the freshest source and re-run the query.
4. **Browsers cache 503 responses.** After fixing server-side issues, always test with `curl -v` from the command line before assuming the fix didn't work. A successful 302/200 from curl combined with a 503 in the browser is almost always cache.
5. **Blast-radius-aware recovery.** Before reinstalling anything, confirmed WordPress PVCs were still `Bound` to ensure user data couldn't be lost by a scoped-wrong reinstall. The fix only touched the `monitoring` namespace.

---

## Feature — NetworkPolicy: MariaDB isolation

### What was built

A Kubernetes NetworkPolicy (`kubernetes/wordpress/network-policy.yaml`) that restricts all ingress traffic to the MariaDB pod to only the WordPress pod on TCP port 3306.

### Manifest

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mariadb-allow-wordpress-only
  namespace: wordpress
spec:
  podSelector:
    matchLabels:
      app: mariadb
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: wordpress
      ports:
        - protocol: TCP
          port: 3306
```

### How it works

- `podSelector.matchLabels.app: mariadb` — targets only MariaDB pods
- `policyTypes: [Ingress]` — controls inbound traffic (egress is unrestricted)
- `ingress.from.podSelector.matchLabels.app: wordpress` — allows traffic only from pods with the `app: wordpress` label
- `ports: TCP/3306` — limits allowed traffic to the MySQL port only
- Any pod without the `app: wordpress` label in the `wordpress` namespace, or any pod from another namespace, is blocked from reaching MariaDB

### Why this matters

Without NetworkPolicy, any pod in the cluster can connect to MariaDB — including compromised pods in other namespaces. This follows the principle of least privilege: MariaDB only needs to communicate with WordPress, so that's all that's allowed.

### Deployment

Deployed via Argo CD GitOps — pushed to `kubernetes/wordpress/`, Argo CD syncs automatically. No Ansible or CI trigger needed.

### Interview talking point

NetworkPolicy is Kubernetes' built-in firewall at the pod level. By default, all pods can talk to all pods (flat network). NetworkPolicy is an allowlist — once applied to a pod, all traffic not explicitly allowed is denied. This is defence-in-depth: even if an attacker gains code execution in a pod, they can't pivot to the database unless they're running in a pod with the right label in the right namespace. The CNI plugin (Calico, Cilium, etc.) enforces the policy — without a compatible CNI, NetworkPolicy objects are ignored silently.

---

## Feature — WP-CLI runner, and the domain cleanup it enabled

### Why a separate pod

The `wordpress:php8.2-apache` image ships no `wp` binary — confirmed with `command -v wp` → `NOT_INSTALLED`. The official `wordpress:cli` image contains WP-CLI but not WordPress, and is designed to be pointed at an existing install's files and database.

It runs as a long-lived Deployment mounting `wordpress-pvc` alongside the live site. That is legal for the same reason Incident #26 was dangerous: **ReadWriteOnce restricts a volume to one node, not one pod.** The property that allowed two `mariadbd` processes to fight over one data directory is exactly what allows an administrative tool to share the web root safely.

### Two details that would have caused subtle damage

**`runAsUser: 33`.** The image would otherwise run as root, and every file WP-CLI created — installed plugins, generated config — would be root-owned on a volume the WordPress pod accesses as `www-data`. WordPress would then fail to update or delete exactly the files it had just been told to install, with permission errors far removed from the cause.

**NetworkPolicy entry for `app: wpcli`.** The third workload to need one, after `app: wordpress` and `app: backup`. A missing entry does not produce a connection error — Calico drops the packets and `wp` hangs until timeout. This is now a standing rule: any new workload that touches the database needs its label added, or it fails silently.

**`WORDPRESS_CONFIG_EXTRA` deliberately unset.** The web pod defines `WP_HOME`/`WP_SITEURL` there, which override the database at runtime. Setting the same variable on the CLI pod would make `wp option get siteurl` report the constant rather than what is stored — an administrative tool that lies about state is worse than no tool.

### The cleanup: removing the stale-domain landmine

Phase 1 moved the site to the root domain using runtime constants and deliberately never touched the database. That made the change trivially revertible, but left `siteurl` and `home` reading `http://blog.lennardjohn.org`. The site worked only because the constants masked them — remove the constants and it would snap back to the old HTTP URL.

With verified backups in place (Phase 0), the database could safely be brought into line. A fresh backup was taken immediately before the write.

```bash
wp search-replace "http://blog.lennardjohn.org" "https://lennardjohn.org" \
  --all-tables-with-prefix --precise --skip-columns=guid --report-changed-only
```

Dry run first:

```
wp_options  option_value  2  PHP
wp_posts    post_content  2  PHP
wp_posts    guid          5  PHP
wp_users    user_url      1  PHP
Success: 10 replacements to be made.
```

**Half the candidate replacements were GUIDs, and rewriting them would have been a mistake.** `wp_posts.guid` is not a URL despite looking like one — WordPress uses it as a permanent opaque identifier for feed items and never resolves it. Changing it makes every RSS reader treat existing posts as brand new. Skipping that column reduced the change from 10 replacements to the 5 that mattered.

`--precise` forces PHP-based replacement rather than a SQL `REPLACE()`. Serialized PHP data — widget settings, theme mods, plugin options — embeds string lengths (`s:24:"http://blog.lennardjohn.org"`). A naive SQL replace changes the string but not the declared length, silently corrupting the value into something PHP cannot unserialize.

The constants were **kept** rather than removed: they now agree with the database, and they additionally protect the site if an older backup carrying the previous URLs is ever restored.

Verified after: `siteurl`/`home` correct, only `guid` values still referencing the old domain (intended), root `200`, `/wp-admin/` `302` to login, `blog.` subdomain `301`.

### Interview talking points

1. **The same storage property is a hazard in one context and a feature in another.** RWO permitting multiple pods per node nearly caused database corruption in Incident #26, and is what makes a shared administrative tool pod possible here. The property is neutral; whether it is safe depends entirely on whether the workload tolerates concurrent writers.
2. **Container UID is part of the interface when a volume is shared.** Two containers mounting one PVC must agree on ownership, or one silently creates files the other cannot manage.
3. **Read the dry run, do not just run it.** The dry run revealed that half the proposed replacements were in a column that must never be rewritten. The command would have "succeeded" either way — correctness here came from understanding what `guid` is for, not from the tool reporting an error.
4. **Serialized data is why `--precise` exists.** PHP serialization embeds string lengths, so byte-level replacement corrupts any value whose length changes. This is the single most common way a WordPress domain migration destroys plugin settings.
5. **Sequencing made the risky change safe.** Editing the database was explicitly rejected in Phase 1 as too risky to revert. The same edit became routine once Phase 0 provided a verified restore path. The action did not get safer — the recovery position did.

---

## Feature — Camp checkout fields, and the API that silently does nothing

### The trap

The requirement was ordinary: collect student name, year level and an emergency contact at checkout. Every tutorial and most Stack Overflow answers reach for `woocommerce_checkout_fields`.

That filter applies **only to the classic checkout**. WooCommerce 11 installs the block checkout by default (`wp:woocommerce/checkout` in the page content), and against it the filter registers cleanly, throws no error, logs nothing, and renders no fields whatsoever.

Checking which checkout was actually installed took one command and avoided writing code that would have appeared correct in review:

```
wp post get 72 --field=post_content
<!-- wp:woocommerce/checkout -->
```

The correct mechanism is the Additional Checkout Fields API (`woocommerce_register_additional_checkout_field`, WooCommerce 8.9+), which also handles persistence, admin order display and inclusion in emails - all of which would otherwise have been hand-written hooks.

### Design decisions

**Order level, not item level.** `sold_individually` caps each session at one per order, so an order corresponds to exactly one student. Per-item fields would have added complexity for a case that cannot occur.

**Validation beyond required.** Required-ness is satisfied by "n/a". For an emergency phone that is a present-but-useless value with real consequences, so it is validated for at least seven digits.

**Medical and dietary details are deliberately absent.** They are sensitive data about minors, they would live in the orders table, and therefore in every nightly backup and every restore. Collected separately closer to the camp date instead - the same operational outcome with a materially smaller obligation.

### Verification

Registration alone does not prove the data survives. A test order was created programmatically, the fields persisted and read back, and the order deleted:

```
lj/student-name        Test Student
lj/student-year        year-9
lj/emergency-name      Test Parent
lj/emergency-phone     0211234567
```

### Interview talking points

1. **Check which implementation you are extending before extending it.** Classic and block checkout share a name and almost nothing else. The failure mode here is not an exception - it is silence, which is far more expensive to diagnose than a crash.
2. **Prefer the API that owns the whole lifecycle.** The Additional Fields API handles storage, admin rendering and email inclusion. The classic approach needs four separate hooks, each an opportunity to forget one and lose data that was successfully collected.
3. **Required is not the same as valid.** The distinction matters most exactly where the data matters most.
4. **Data you do not collect cannot leak.** Excluding medical information was not a technical constraint but a deliberate reduction in blast radius, given the data would otherwise propagate into every backup.

---

## Incident #29 — Brevo SMTP: the client library named the wrong failure

**Symptom:** With credentials in place, every send failed:

```
WP_MAIL_FAILED: SMTP Error: Could not authenticate.
```

That message points squarely at bad credentials. It was wrong.

**Diagnostic steps:**

1. Verified the credentials reached PHP at all — a real possibility, since Apache does not automatically expose container environment variables to `getenv()`:
   ```
   SMTP_HOST  smtp-relay.brevo.com
   SMTP_USER  b5d952001@smtp-brevo.com
   SMTP_PASS  set (90 chars)
   ```
2. Checked credential *shape* without printing secrets — a trailing newline introduced by a shell is a classic cause:
   ```
   user len 24, trimmed 24  OK      ends with @smtp-brevo.com: yes
   pass len 90, trimmed 90  OK      starts with xsmtpsib-:     yes
   ```
   Both well-formed, and not mangled in transit.
3. Enabled `SMTPDebug = 2` to capture the raw SMTP conversation rather than PHPMailer's summary of it.

**Root cause:**

```
CLIENT -> SERVER: AUTH CRAM-MD5
SERVER -> CLIENT: 525 5.7.1 Unauthorized IP address
```

Brevo's **IP authorisation** feature was rejecting the connection on source IP, *before* evaluating the key at all. Nothing was wrong with the credentials. PHPMailer collapses any failed AUTH exchange into "Could not authenticate", discarding the server's actual explanation.

**Fix:** disabled IP authorisation in Brevo rather than allowlisting the cluster egress IP (`116.251.171.15`).

That choice was deliberate. The egress IP is a residential connection and can change on any reboot, ISP event or lease renewal. When it changed, booking confirmations would stop sending **silently** — no error surfaced to the site, no alert, and the first sign would be a parent reporting they never received a receipt. A 90-character key is strong authentication by itself; an allowlist that fails unpredictably and invisibly is a worse trade.

**Verification:**
```
235 2.0.0 Authentication succeeded
MAIL FROM:<holidaycamp@lennardjohn.org>  -> 250 accepting mail
RCPT TO:<...>                            -> 250 will make sure it gets this
250 2.0.0 OK: queued
```

**Interview talking points:**

1. **Client libraries summarise; servers explain.** "Could not authenticate" is the library's interpretation of a failed AUTH exchange. The server said `525 Unauthorized IP address` — a different problem with a different fix. The obvious next step suggested by the library message, regenerating the key, would have been wasted effort.
2. **Get to the wire protocol.** SMTP and most protocols underneath this stack are inspectable. One debug flag turned an ambiguous failure into an exact answer. Reach for the raw exchange before theorising.
3. **Eliminate cheap causes in a way that produces evidence.** Checking credential length and prefix without printing the secret ruled out malformed input and shell-introduced whitespace in seconds, and made the "credentials are fine" conclusion defensible rather than assumed.
4. **Choose the failure mode you can detect.** IP allowlisting on a dynamic residential IP fails silently at an unpredictable future date. Given two security postures, prefer the one whose failure is visible — or at minimum, alert on the one that is not.
5. **A missing Secret must not be an outage.** The `secretKeyRef` entries use `optional: true`, so absent credentials fall through to PHP `mail()`. Without that flag the pod refuses to start, and deploying the manifest before creating the Secret would have taken the entire site down in order to configure email.

---

## Incident #28 — A correct deploy that looked like a failed one: CDN cache keys

**Symptom:** Responsive CSS fixes were committed, pushed, reconciled by Argo CD and confirmed present in the running pod — and had no effect on the live site. Repeated deploys changed nothing.

**Diagnostic:** compared the file on disk in the pod against what the CDN was serving.

```
pod:    17188 bytes, new rules present
served: 13207 bytes, cf-cache-status: HIT, age: 372, cache-control: max-age=14400
```

**Root cause:** the stylesheet is served through Cloudflare with a four-hour TTL. WordPress appends `?ver=` to the enqueued URL, and that query string forms part of the cache key. The version came from the theme header — a static `1.0.0` — so **the cache key never changed when the file did.** Cloudflare kept serving the previous copy while the origin was already correct.

This had been silently affecting every theme change made that day.

**Fix:** derive the enqueue version from the file modification time instead of the theme header:

```php
$style_path = get_stylesheet_directory() . '/style.css';
$style_ver  = file_exists( $style_path ) ? (string) filemtime( $style_path ) : ...;
wp_enqueue_style( 'lennardjohn-child', ..., $style_ver );
```

The theme is re-cloned from Git into a fresh `emptyDir` on every pod start, so mtime changes on every deploy and the cache busts automatically — no version number to remember to bump.

**Interview talking points:**

1. **"Deployed" is not "delivered".** There are several distinct states — committed, reconciled, present on disk, served by the origin, served by the edge, rendered by the browser. A failure at any one of them looks identical from the browser. Naming which state you have actually verified is the difference between debugging and guessing.
2. **Compare origin against edge.** One `wc -c` inside the pod and one `curl` through the CDN located the problem immediately. Testing only in a browser conflates at least three caches.
3. **Cache invalidation should be automatic, not remembered.** A version number a human must bump will eventually not be bumped. Deriving it from mtime makes correctness a property of the deploy rather than of someone's discipline.
4. **The same class of bug appeared twice in one session** — see Incident #27, where `kubectl cp` served stale content. Both presented as "my change did nothing". When that happens, suspect a stale copy before suspecting the change.

---

## Incident #27 — `kubectl cp` silently re-applied stale content

**Symptom:** A content deploy reported success for all 19 pages and changed nothing on the site:

```
updated  home (#7)
updated  about (#8)
...
```

Every page reported `updated`. Every page kept its previous content.

**Diagnostic:** compared the source file on the master node against the copy inside the pod.

```
master:  /tmp/content/kubernetes.html           11848 bytes  (new)
pod:     /tmp/content/kubernetes.html            4750 bytes  (OLD)
pod:     /tmp/content/content/kubernetes.html   11848 bytes  (new, nested)
```

**Root cause:** `kubectl cp <dir> pod:/path` **nests the copy when `/path` already exists**, creating `/tmp/content/content/` and leaving the previous files at `/tmp/content/`. The bootstrap script read the stale files and dutifully re-applied the old content to every page, reporting `updated` for each one.

The bug was latent. Earlier deploys had included `kubectl rollout restart`, which recreates the pod and wipes `/tmp` — so the destination never existed and the copy landed correctly. The first deploy that skipped the restart exposed it.

**Fix:** delete the destination inside the pod before copying, and verify:

```bash
kubectl exec -n wordpress $POD -- rm -rf /tmp/content
kubectl cp /tmp/content wordpress/$POD:/tmp/content
kubectl exec -n wordpress deploy/wpcli -- ls -d /tmp/content/content   # must not exist
```

**Interview talking points:**

1. **A failure that reports success is the most expensive kind.** The script output was indistinguishable from a correct run. Nothing errored, nothing warned, and the only evidence was that the site did not change. Tools that report their *intent* rather than their *effect* need independent verification.
2. **`kubectl cp` inherits `cp` semantics, including the surprising one.** Copying a directory onto an existing directory nests rather than merges — predictable in hindsight, invisible in output.
3. **Incidental conditions mask bugs.** A `rollout restart` that existed for an unrelated reason had been hiding this for days. Removing an apparently unrelated step surfaced it, which is the signature of a latent bug rather than a new one.
4. **Verify the input, not just the output.** The fix that mattered was not the `rm -rf`; it was checking that the file inside the pod matched the file on disk before trusting anything downstream of it.

---

## Feature — Tech camp bookings: stock as a capacity cap

### The requirement

Sell places on a five-day AI camp for Year 7–10 students: two daily sessions, a hard cap of 28 per session, online payment, a visible indicator of how full each session is, and a route for parents to reach the owner once a session fills.

### Why WooCommerce stock, and not an events plugin

Each session is a WooCommerce product with `manage_stock=true`, `backorders=no` and `sold_individually=true`. **Stock is the capacity cap.** That is not a workaround — it is exactly what stock management does, and it means WooCommerce resolves the race when two parents buy the last place simultaneously, rather than that logic being hand-written.

The alternative considered was Eventin (~$79/yr), whose waitlist tier could not be confirmed from vendor documentation. WooCommerce was already installed and gives a hard, race-safe cap for nothing.

### The full-day pricing trap

A single session is $140; both sessions together are $200 rather than $280.

The obvious implementation — a third "full day" product — is wrong, and wrong in a way that only shows up once real bookings exist. A full-day SKU carries **its own stock**, and nothing then prevents 28 morning bookings plus 28 full-day bookings putting 56 children in a room built for 28. WooCommerce cannot share stock between products, and Product Bundles is a paid extension.

Selling the two real sessions and applying a cart-level discount keeps every capacity count honest, because both sessions genuinely decrement:

```php
$discount = ( $morning_cost + $after_cost ) - lj_camp_full_day_price();
$cart->add_fee( 'Full-day discount', -$discount );
```

The discount is **derived**, not hardcoded, so changing the session price keeps the arithmetic correct. Verified: subtotal 280, fee -80, total 200.00.

### The capacity indicator, and the bug in it

`[lj_camp_classes]` renders each session with a bar in one of three states driven by real stock: open, filling (>=75% taken), and full. When a session is full the booking button is **replaced** by an email link rather than disabled, so a parent has somewhere to go instead of a dead end.

WooCommerce tracks only *remaining* stock, so the original class size is stored separately as `_lj_capacity` post meta, and `taken = capacity - stock`.

**The bug:** that meta was written only in the `create` branch of the upsert. The products already existed, so the `update` branch ran and the meta was never written. The shortcode fell back to `capacity = remaining`, and a session with 14 of 28 places sold rendered as **"0 of 14 places taken" with an empty bar**.

Fixed by writing the meta on both paths. Verified across the range: `28 -> 0/28 0%`, `14 -> 14/28 50%`, `7 -> 21/28 75% amber`, `3 -> 25/28 89%`, `0 -> 28/28 100% red + email link`.

### Safety properties built in deliberately

- **Products are created `draft` and unpriced.** WooCommerce refuses to sell a product with no price, so a class cannot be booked even if published by accident — a far safer placeholder than `0.00`, which would give places away free.
- **`sold_individually`** stops one order consuming a whole class, at the cost of a parent with two children placing two bookings.
- **Overflow classes** exist as drafts. When a session fills, publishing the matching second class makes it bookable with no code change.
- **`stock_quantity` is never updated by the bootstrap after creation** — re-running it would otherwise wipe the record of how many places had sold.

### Interview talking points

1. **Model capacity where the race is already solved.** Writing a booking cap by hand means writing the concurrency control by hand. Stock management already handles simultaneous checkout of the last unit; using it removes an entire class of bug rather than solving it.
2. **A convenience price can break a physical constraint.** The full-day product would have been the natural implementation and would have oversold the room. The question that exposed it was not "how do I price this?" but "what physically limits this?" — 28 seats, not 28 transactions.
3. **A plausible wrong number is worse than an obvious error.** "0 of 14 places taken" looked entirely reasonable on a live booking page. Only checking it against known stock values revealed it. Test the states, not just that the code runs.
4. **Idempotent scripts need care about which fields they own.** The bootstrap declares capacity and price; the live system owns remaining stock. Getting that boundary wrong either wipes sales data or lets configuration drift.

---

## Incident #26 — MariaDB rollout deadlock: `RollingUpdate` against a ReadWriteOnce PVC

**Symptom:** After the Phase 2 memory increase, WordPress rolled out cleanly but MariaDB did not:

```
kubectl rollout status deploy/mariadb -n wordpress --timeout=300s
Waiting for deployment "mariadb" rollout to finish: 1 old replicas are pending termination...
error: timed out waiting for the condition
```

```
mariadb-54445b89cc-kn4vp   0/1   CrashLoopBackOff   6 (16s ago)   9m41s   k8s-worker-1
mariadb-57b6fc8774-rtzht   1/1   Running            1 (6d16h ago) 6d16h   k8s-worker-1
```

Both pods on the same node. The site stayed up throughout — the old pod kept serving.

**Diagnostic:**

```
kubectl get deploy -n wordpress mariadb   -o jsonpath="{.spec.strategy.type}"  → RollingUpdate
kubectl get deploy -n wordpress wordpress -o jsonpath="{.spec.strategy.type}"  → Recreate
```

The asymmetry was the whole answer. Confirmed in the crashing pod's logs:

```
[ERROR] InnoDB: Unable to lock ./ibdata1 error: 11
[Note]  InnoDB: Check that you do not already have another mariadbd process using
        the same InnoDB data or log files.
[ERROR] InnoDB: Plugin initialization aborted with error Generic error
[ERROR] Failed to initialize plugins.
[ERROR] Aborting
```

**Root cause:** ReadWriteOnce does not mean "one pod". It means **one node**. Multiple pods scheduled to that same node may all mount the volume simultaneously. The local-path PV pins every MariaDB pod to `k8s-worker-1`, so a rolling update did not fail to schedule — it succeeded, mounted the live data directory, and started a second `mariadbd` against files already open by the running instance.

`error: 11` is `EAGAIN` — the advisory lock on `ibdata1` is held. **InnoDB's file lock is the only thing that prevented two database processes writing the same files.** The CrashLoopBackOff is the safety mechanism working, not the failure.

`Recreate` was already applied to WordPress for exactly this reason and is documented in the knowledge base. MariaDB never received it. The bug was latent from the original deployment and could only surface on the first change to the MariaDB **pod spec** — the Phase 2 memory increase was the first such change in the deployment's life.

**Fix** — `kubernetes/wordpress/mariadb.yaml`:

```yaml
spec:
  replicas: 1
  strategy:
    type: Recreate
```

After sync: `deployment "mariadb" successfully rolled out`.

**Interview talking points:**

1. **ReadWriteOnce is a node-scoped guarantee, not a pod-scoped one.** This is one of the most commonly misread parts of the Kubernetes storage model. RWO permits many pods on one node to mount the same volume — which is precisely what makes rolling updates dangerous for any single-writer workload on RWO storage. (`ReadWriteOncePod`, added in 1.22 and GA in 1.29, is the access mode that actually means one pod.)
2. **Latent bugs surface on the first change, not at deploy time.** The wrong strategy sat harmlessly in Git for the deployment's entire life because nothing had ever triggered a pod replacement. Config that is never exercised is untested config, and the day it is exercised is rarely a convenient one.
3. **Inconsistency between two similar objects is a strong signal.** WordPress and MariaDB are the same shape — single replica, RWO PVC, same namespace — yet had different strategies. One command comparing the two found the cause. When one of a matched pair works and the other does not, diff them before reading logs.
4. **The failure was safe because a lower layer was defensive.** InnoDB refused to open files another process held. Kubernetes would happily have run two database processes on one data directory; the database prevented it. Understanding which layer is actually protecting your data matters when reasoning about what "it didn't break" proves.
5. **Stateful workloads want StatefulSets.** A Deployment with an RWO PVC is a workable compromise for a single-instance database, but the correct primitive provides ordered, one-at-a-time replacement by design rather than by remembering to set `strategy: Recreate`.

---

## Incident #25 — Backup CronJob bring-up: three failures, and the diagnostic that found them

The backup CronJob failed on every run for its first four attempts. Each failure had a different cause, and the first two were invisible because the pod deleted itself within ~20 seconds.

### Failure 0 — losing the evidence

```
kubectl logs -n wordpress -f job/backup-manual-01
Error from server (BadRequest): container "restic" in pod "..." is waiting to start: PodInitializing
kubectl logs -n wordpress -f job/backup-manual-01
error: timed out waiting for the condition
```

`kubectl logs -f` on a Job defaults to the *first* container. With an initContainer still running, there is nothing to attach to, and by the time the command was retried the pod had failed, hit `backoffLimit`, and been cleaned up. Two runs produced zero diagnostic information.

**The technique that fixed this:**

```bash
kubectl create job -n wordpress --from=cronjob/wordpress-backup backup-manual-03
sleep 15
kubectl logs -n wordpress -l job-name=backup-manual-03 --all-containers=true --prefix=true --tail=100
```

`--all-containers` captures init and main containers together, `--prefix` labels which is which, and the fixed `sleep` beats the cleanup. This turned "the pod died and I don't know why" into an exact error message in one command. For short-lived, self-deleting workloads, capture logs on a timer rather than trying to attach to them.

### Failure 1 — shell word-splitting destroyed the SFTP command

```sh
RESTIC="restic -o sftp.command=$SFTP_CMD"
$RESTIC snapshots
```

`$SFTP_CMD` contains spaces (`ssh -i /ssh/id_ed25519 -o ...`). Unquoted expansion of `$RESTIC` splits on every one of them, so restic received `-o sftp.command=ssh` and then parsed `-i`, `/ssh/id_ed25519` and the remaining ssh flags as its own arguments.

A shell variable cannot hold a command with embedded spaces and be re-expanded safely. The fix is a function, where the option can stay quoted and `"$@"` forwards the subcommand intact:

```sh
r() {
  restic -o "sftp.command=$SFTP_CMD" "$@"
}
r snapshots
```

### Failure 2 — root is localhost-only in the MariaDB image

```
mariadb-dump: Got error: 1045: "Access denied for user 'root'@'10.96.140.20'
(using password: YES)" when trying to connect
```

The password was correct. The grant was not: the official `mariadb` image creates `root@localhost`, so root cannot authenticate from any other pod. The source IP in the error (`10.96.140.20`, a pod address in the Calico range) is the giveaway — the connection arrived over the network, not the socket.

The original justification for using root was that `--routines`, `--triggers` and `--events` need elevated privileges. That reasoning did not survive contact with the requirement: **a stock WordPress schema contains no stored routines and no scheduled events**, so those flags backed up nothing. The `wordpress` user holds `ALL PRIVILEGES` on its own database — including `TRIGGER` — and demonstrably connects cross-pod, because that is how the site itself works.

Fix: dump as the application user with `--single-transaction --quick --triggers`, dropping `--routines` and `--events`. Least privilege turned out to be both more correct and more functional than the elevated credential.

Note the asymmetry this creates, which is *not* a contradiction: the **restore** runbook does use root, via `kubectl exec` into the MariaDB pod. That executes inside the container, where `root@localhost` is exactly the grant that exists.

### Failure 3 — testing the old spec

```
not synced yet
job.batch/backup-manual-04 created
mariadb-dump: Got error: 1045: "Access denied for user 'root'@'10.96.140.21'
```

The credential fix was already committed and pushed, but Argo CD had not yet reconciled it. `kubectl create job --from=cronjob/...` snapshots the CronJob **as currently deployed in the cluster**, not as it exists in Git — so the job faithfully re-ran the old, broken spec and reproduced the identical error.

The guard is to block on the sync rather than assume it:

```bash
until kubectl get cronjob -n wordpress wordpress-backup -o yaml | grep -q MARIADB_USER; do
  echo "waiting for argo..."; sleep 15
done
```

Or force it: `kubectl -n argocd patch app wordpress --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'`

### Interview talking points

1. **Preserving evidence is step one.** Two debugging cycles were wasted because the pod deleted itself before its logs could be read. With ephemeral workloads, the first move is to make the failure observable — `--all-containers --prefix` on a timer — not to start guessing at causes.
2. **A variable is not a command.** Storing a multi-word command in a shell variable and re-expanding it unquoted is one of the oldest bugs in shell scripting. Functions with `"$@"` are the correct construct because quoting survives.
3. **"Access denied" is about identity, not just secrets.** In MySQL/MariaDB the account is `user@host`; `root@localhost` and `root@%` are different accounts with different grants. The client IP embedded in the error message tells you which one was attempted, and that it arrived over TCP rather than the local socket.
4. **Interrogate privilege escalation.** Reaching for root was justified by a requirement (`--routines --events`) that did not actually apply to this schema. When elevated credentials appear necessary, check whether the feature needing them is one you actually use — the least-privilege path was simultaneously simpler and the only one that worked.
5. **In GitOps, pushed is not deployed.** There is a real window between `git push` and reconciliation. Any test run inside that window silently exercises the previous version, and the identical error message makes it look like the fix failed rather than that it was never applied. Gate tests on observed cluster state, never on having pushed.

---

## Feature — Phase 0: encrypted off-cluster backups with restic

### Why this was built before anything else

The platform plan (LMS, payments, camp registrations) creates data that exists nowhere in Git. The cluster stores it on `local-path` PVCs — a directory on a single node with no replication. Two prior incidents established the pattern: Incident #23 (Helm release vanished; Argo CD rebuilt the namespace and ingress but not the Helm-managed resources) and the WordPress content gap noted during the root-domain switch.

The through-line: **GitOps reconciles declarations, not data.** Argo CD guarantees the platform can be rebuilt. It guarantees nothing about what is on it. Taking payments and storing children's details on unbacked single-node storage would have been the actual risk in this project — not any of the plugin or licensing decisions.

### Design decisions

**restic over `mysqldump` + `tar.gz`.** Client-side encryption was the deciding factor: these backups will hold minors' registration data and payment records, and an unencrypted dump sitting on a host is a breach waiting for a reason. restic also brings deduplication (nightly fulls do not multiply storage), declarative retention (`forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6`), and `check --read-data-subset`, which verifies the data rather than assuming it.

**Proxmox host over Cloudflare R2.** Chosen for a first iteration. The limitation is documented rather than glossed over: the Proxmox host runs the VMs the cluster lives on, so this covers node failure, PVC loss and accidental deletion — but not loss of the host itself. R2 remains the follow-up for genuine off-site recovery.

**SFTP over NFS.** NFS would have required `nfs-common` on every node, which means editing `ansible/**`, which triggers the GitHub Actions pipeline that has been failing. SFTP keeps everything inside the container. Verified from the [official Dockerfile](https://raw.githubusercontent.com/restic/restic/master/docker/Dockerfile) that `restic/restic` installs `ca-certificates fuse openssh-client tzdata jq` — so the sftp backend works with no custom image and no registry to publish to.

### The trap that would have failed silently

The existing NetworkPolicy allowed ingress to MariaDB only from pods labelled `app: wordpress`:

```yaml
ingress:
  - from:
      - podSelector:
          matchLabels:
            app: wordpress
    ports:
      - protocol: TCP
        port: 3306
```

The backup pod carries `app: backup`. Calico would have **dropped the connection silently** — not refused it. `mariadb-dump` would hang until the job timed out, and the failure mode is a CronJob that appears to run every night while producing nothing usable. Fixed by adding a second `podSelector` for `app: backup`.

This is the general hazard with default-deny networking: adding a new workload that talks to a protected service fails by *hanging*, not by erroring, and the symptom appears nowhere near the cause.

### Implementation details worth keeping

**`MYSQL_PWD` instead of `--password=`.** A password passed as a command-line argument is visible in the process list to anything that can run `ps` in that container.

**`StrictHostKeyChecking=yes` with a pre-seeded `known_hosts`.** The obvious shortcut is `accept-new`, but the pod filesystem is ephemeral — every nightly run would start with an empty `known_hosts` and blindly trust whatever answered. That is not host verification, it is a nightly MITM window. The host key is captured once with `ssh-keyscan` and shipped in the Secret.

**`readOnly: true` on the PVC mount.** A backup job must never be able to modify what it is backing up.

**No `nodeSelector` needed.** The local-path PV carries node affinity, so binding the PVC pins the pod to the correct node automatically. RWO permits a second pod on the *same* node, which is what lets the backup mount the volume alongside the running WordPress pod.

**`concurrencyPolicy: Forbid`.** Two restic processes against one repository contend on locks.

**Database dumped, not file-copied.** The MariaDB PVC is deliberately not backed up as raw files — a copy of live InnoDB files is not crash-consistent. `mariadb-dump --single-transaction` is the correct recovery path.

**root credentials for the dump.** `--routines --triggers --events` require privileges the application user does not hold. Noted explicitly rather than left as an unexplained choice.

### Restore drill — verified 2026-08-13

The backup was not considered complete until a restore had actually been performed. Result: table counts and `wp_posts` row counts matched exactly between the live database and the restored copy.

The drill was designed so it can be repeated safely at any time, which mattered more than doing it once:

**It never writes to the live database.** The dump is taken with `--databases`, so it carries `CREATE DATABASE` and `USE \`wordpress\`` statements — piping it into MariaDB would silently overwrite the running site. A "restore test" that destroys production on a typo will not be run twice. Stripping those two statements and redirecting into `wordpress_restoretest` makes the drill repeatable and boring, which is the goal.

**It verifies by comparison, not by absence of errors.** A restore that throws no errors has not been verified — it has merely completed. Comparing table counts and row counts between live and restored turns "it seemed to work" into evidence.

**Cheap structural checks first.** `grep -c "^CREATE TABLE"` and checking for the trailing `-- Dump completed` marker catch a truncated dump before any import is attempted. A dump cut short by a full disk or killed process looks perfectly normal until the missing tail is needed.

**The drill and real recovery are documented separately.** They genuinely differ: recovery imports the `CREATE DATABASE`/`USE` statements the drill strips, and additionally restores files into the PVC. Conflating them would make the safe procedure dangerous or the real one incomplete.

### Interview talking points

1. **Sequencing is a design decision.** Backups were built before the LMS, payments or camp signup, because every one of those creates irreplaceable data. Building features first and backups later means the window of maximum data value coincides with the window of zero protection.
2. **Default-deny networking fails by hanging.** A NetworkPolicy drop is silent by design — no RST, no error, just a timeout. Any new workload added to a namespace with default-deny needs its policy entry considered up front, because the failure surfaces far from its cause.
3. **"Off-cluster" is not binary.** Writing to the Proxmox host removes the node-failure and accidental-deletion risks but not the single-physical-machine risk. Naming precisely which failure modes a backup does and does not cover is more useful than calling it "off-site" and moving on.
4. **Encryption changes who you have to trust.** Client-side encryption means the storage host never holds plaintext, so the backup target does not need to be as trusted as the source. The cost is a passphrase whose loss is unrecoverable — a real operational obligation, not a checkbox.
5. **Verification belongs in the job.** `restic check --read-data-subset=5%` runs nightly. The classic backup failure is not corruption, it is a job that quietly stopped running months ago and looks identical to a healthy one until a restore is attempted.
6. **Constraints shaped the architecture.** SFTP was chosen over NFS specifically because NFS meant touching `ansible/**` and triggering a known-broken CI pipeline. Working around a real constraint produced a design with fewer moving parts anyway.

---

## Incident #24 — `ERR_TOO_MANY_REDIRECTS` on `/wp-admin/`: ingress-nginx discards Cloudflare's `X-Forwarded-Proto`

**Symptom:** After moving the root domain to WordPress, `https://lennardjohn.org/` loaded fine (HTTP 200) but `https://lennardjohn.org/wp-admin/` failed in the browser with `ERR_TOO_MANY_REDIRECTS`.

**Diagnostic steps:**

1. Checked the redirect target without following it:
   ```
   curl -sS -o /dev/null -D - --max-redirs 0 https://lennardjohn.org/wp-admin/

   HTTP/1.1 302 Found
   location: https://lennardjohn.org/wp-admin/
   Server: cloudflare
   ```
   The `Location` header points at **the exact URL that was requested**. A self-referential 302 is an unconditional infinite loop — the browser is not at fault and no amount of cache clearing will help.

2. Confirmed the root path was healthy:
   ```
   curl -sS -o /dev/null -D - --max-redirs 0 https://lennardjohn.org/

   HTTP/1.1 200 OK
   ```
   Root 200 + admin loop is the signature of a scheme-detection problem, not a routing or backend problem. Ingress, Service and pod were all working — WordPress was choosing to redirect.

**Root cause:** The `WORDPRESS_CONFIG_EXTRA` block added during the root-domain switch made the HTTPS flag conditional:

```php
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    $_SERVER['HTTPS'] = 'on';
}
```

The assumption was that Cloudflare's `X-Forwarded-Proto: https` reaches PHP. It does not. **`ingress-nginx` sets `use-forwarded-headers: false` by default**, which means it deliberately ignores inbound `X-Forwarded-*` headers and regenerates them from the connection it actually received. Since `cloudflared` connects to the controller over plain HTTP, ingress-nginx overwrites the header with `X-Forwarded-Proto: http`.

That default is a security measure, not a bug: trusting client-supplied `X-Forwarded-*` headers by default would let any client spoof its origin scheme and IP. The header is only trustworthy when you know a proxy you control sits in front, which is exactly what the setting exists to declare.

So the condition never evaluated true, `$_SERVER['HTTPS']` stayed unset, and WordPress saw an HTTP request for a site whose `WP_SITEURL` is `https://`. `/wp-admin/` additionally runs through `auth_redirect()`, which forces a redirect to the canonical HTTPS admin URL — producing the self-referential 302 and the loop. The homepage escaped because it does not run that check.

**Two possible fixes considered:**

| Option | Scope | Verdict |
|---|---|---|
| Set `use-forwarded-headers: true` in the ingress-nginx ConfigMap | **Cluster-wide** — changes header handling for Grafana, Argo CD and every future Ingress | Rejected. Blast radius far exceeds the problem. |
| Force `$_SERVER['HTTPS'] = 'on'` in `wp-config.php` | **WordPress only** | Chosen. |

**Fix** — `kubernetes/wordpress/wordpress.yaml`:

Before:
```php
define('WP_HOME','https://lennardjohn.org');
define('WP_SITEURL','https://lennardjohn.org');
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    $_SERVER['HTTPS'] = 'on';
}
```

After:
```php
define('WP_HOME','https://lennardjohn.org');
define('WP_SITEURL','https://lennardjohn.org');
$_SERVER['HTTPS'] = 'on';
```

Forcing the flag unconditionally is correct **in this specific topology** because there is exactly one external path to the pod — Cloudflare → tunnel → ingress-nginx — and it is always HTTPS from the client's perspective. There is no plain-HTTP public route that could be misrepresented. On a cluster that also served the same pod over real HTTP, this would be wrong.

**Interview talking points:**

1. **A self-referential 302 is diagnostically decisive.** `Location` matching the requested URL means the loop is unconditional and server-side. That single `curl` distinguished "the application is choosing to redirect" from "the routing is broken", which eliminated Ingress, Service and DNS in one command. Following redirects (`curl -L`) would have hidden the evidence — `--max-redirs 0` is what exposes it.
2. **The differential — root 200, admin looping — localised the fault.** Same host, same Ingress, same pod, different result. That rules out every shared layer and points at code paths unique to `/wp-admin/`, i.e. `auth_redirect()` and `force_ssl_admin()`.
3. **Know your proxy's trust defaults.** `use-forwarded-headers: false` is a deliberate anti-spoofing default: `X-Forwarded-*` is client-controlled and must not be trusted unless a known proxy sits in front. Writing code that depends on a header without verifying the proxy chain actually forwards it is an assumption, not a design.
4. **Match the fix's blast radius to the problem's blast radius.** Flipping `use-forwarded-headers` cluster-wide to fix one application would have silently changed how every other Ingress handles client headers. A one-line change scoped to WordPress solved the same problem with no collateral surface.
5. **Documenting the wrong turn is the point.** The original config was committed with a confident comment calling the header check "required, not optional". It was wrong, and it was wrong for an interesting reason — the header genuinely is required *in general*, just not obtainable *here*. Keeping the failed attempt in the record is more instructive than a clean-looking history.

---

## Feature — Root domain moved from static landing page to WordPress

### What was built

`lennardjohn.org` was a static nginx page served from a ConfigMap. It now serves WordPress — the same instance already running at `blog.lennardjohn.org`. This is phase 1 of turning the root domain into a platform (Tutor LMS learning platform, resume, projects, "currently working on", and a kids' holiday tech camp signup).

### Why reuse the existing WordPress instead of deploying a second one

A second WordPress at the root domain would mean another WordPress pod, another MariaDB pod, and two more PVCs — roughly 700Mi of additional memory on a cluster that has already had OOM problems on the worker nodes (commits `increase memory size on worker nodes`, `i increase the memory on node now monitor pods just crash`). Reusing the existing instance costs nothing: one Service, one database, one PVC, two Ingress objects.

### Before / after

Before — `kubernetes/landing/kustomization.yaml`:
```yaml
resources:
  - namespace.yaml
  - configmap.yaml
  - deployment.yaml
  - ingress.yaml
```

After:
```yaml
resources:
  - namespace.yaml
  - configmap.yaml
  - deployment.yaml
  # - ingress.yaml
```

New file — `kubernetes/wordpress/root-ingress.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: wordpress-root
  namespace: wordpress
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "64m"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - lennardjohn.org
      secretName: wordpress-root-tls
  rules:
    - host: lennardjohn.org
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: wordpress
                port:
                  number: 80
```

Added to `kubernetes/wordpress/wordpress.yaml`:
```yaml
- name: WORDPRESS_CONFIG_EXTRA
  value: |
    define('WP_HOME','https://lennardjohn.org');
    define('WP_SITEURL','https://lennardjohn.org');
    if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
        $_SERVER['HTTPS'] = 'on';
    }
```

### The two traps this design avoids

**Trap 1 — the WordPress domain move.** WordPress persists its own canonical URL in the `wp_options` table (`siteurl` and `home`). Point a new hostname at WordPress without addressing this and every request 302-redirects back to the old hostname. The conventional fix is `UPDATE wp_options SET option_value=...` plus a search-replace across post content — destructive, and a typo in `siteurl` locks you out of `/wp-admin`, which is where you would normally go to fix it.

Defining `WP_HOME` and `WP_SITEURL` as PHP constants in `wp-config.php` overrides the database values without writing to the database. The official `wordpress` image appends `WORDPRESS_CONFIG_EXTRA` verbatim into `wp-config.php` at container start. Consequences: the setting is declarative, version-controlled, owned by Argo CD, and reversible with `git revert` — and because the database was never touched, rollback is guaranteed lossless.

**Trap 2 — the TLS-termination redirect loop.** Cloudflare terminates TLS at its edge; `cloudflared` forwards plain HTTP to `ingress-nginx`. PHP therefore sees `$_SERVER['HTTPS']` unset. With `WP_SITEURL` set to `https://`, WordPress concludes the request is on the wrong scheme and redirects to the HTTPS URL — which arrives, again, as plain HTTP. `ERR_TOO_MANY_REDIRECTS`.

Setting `$_SERVER['HTTPS'] = 'on'` tells WordPress the client-side connection is already secure, so it stops redirecting. This is the single most common failure mode when putting WordPress behind any reverse proxy or CDN.

**The first attempt at this got it wrong** — it made the assignment conditional on `X-Forwarded-Proto: https`, which never matches in this topology. See Incident #24 for why.

### Why a separate Ingress object rather than adding a host to the existing one

`ingress.yaml` (the `blog.lennardjohn.org` route) is left byte-for-byte unmodified. A rollback deletes a file rather than editing a working route, so the blog cannot be collaterally damaged by a bad revert. Two Ingress objects in one namespace targeting the same Service is entirely valid.

The inverse rule does apply, and is documented in the kustomization comments: **exactly one** Ingress may claim host `lennardjohn.org`. Two Ingresses claiming the same host is undefined behaviour in ingress-nginx — it typically honours the oldest by creation timestamp, which is neither predictable nor stable across a resync. So `landing/ingress.yaml` had to be withdrawn in the same commit that added `root-ingress.yaml`.

### Why no CI pipeline ran

The Cloudflare tunnel config (`terraform/proxmox/cloudflare.tf:61`) already maps `lennardjohn.org` → `ingress-nginx-controller.ingress-nginx.svc.cluster.local`. The tunnel only cares which hostnames reach the cluster, not which Service answers inside it — that is ingress-nginx's job. So no Terraform, no DNS, and no Ansible change was required.

`.github/workflows/deploy.yml` triggers only on:
```yaml
paths:
  - 'terraform/**'
  - 'ansible/**'
```

A `kubernetes/**` change therefore bypasses CI entirely and deploys through Argo CD alone. This mattered practically: the pipeline had been failing repeatedly and the cluster had needed manual rebuilding, so a change that avoids CI was the low-risk path.

### Rollback

```bash
git revert <commit-sha> && git push
```
Argo CD reconciles in ~3 minutes. Nothing to undo in the database. The landing page's Deployment, Service and ConfigMap were never removed — only its Ingress — so the pod is still running and healthy throughout, just unrouted. Restoring the Ingress restores the page instantly, with no image pull or scheduling delay.

### Follow-up — retiring `blog.lennardjohn.org`

Leaving both hosts serving WordPress meant the identical site answered on two URLs. Verified with `curl`:

```
curl -sS -o /dev/null -D - --max-redirs 0 https://blog.lennardjohn.org/
HTTP/1.1 200 OK
```

A `200` rather than a `301` confirms genuine duplicate content — WordPress was serving the blog host directly, not canonicalising it. Search engines treat that as two competing copies and split ranking signals between them.

Fix — an ingress-nginx annotation on the existing blog Ingress:

```yaml
nginx.ingress.kubernetes.io/permanent-redirect: https://lennardjohn.org
```

**Why keep the Ingress instead of deleting it:** the TLS certificate for `blog.lennardjohn.org` is attached to that Ingress. Delete the Ingress and the certificate goes with it, so a browser visiting `https://blog.lennardjohn.org` fails the TLS handshake *before* any redirect can be sent — the user sees a security warning, not a redirect. **The redirect must be served over valid TLS to be useful at all.** This is a general rule when retiring an HTTPS hostname: keep the certificate alive for as long as you want the redirect to work.

The DNS record and Cloudflare tunnel rule were deliberately left in place — removing them means editing `terraform/proxmox/cloudflare.tf`, which triggers the GitHub Actions pipeline. A `kubernetes/**`-only change stays on the Argo CD path.

Known limitation: `permanent-redirect` sends every path to the homepage; it does not map `/blog/some-post` to its equivalent. Path-preserving redirects need `configuration-snippet` with `return 301 https://lennardjohn.org$request_uri;`, but snippet annotations are disabled by default in ingress-nginx ≥1.9 (`allow-snippet-annotations: false`) because they allow arbitrary nginx config injection from any namespace with Ingress permissions. Not worth re-enabling cluster-wide for this.

### Known limitation carried forward

Argo CD manages the pods; it does not manage anything authored *inside* WordPress. Plugins, themes, pages, and Tutor LMS courses live in the `wordpress-pvc` volume and the MariaDB database — neither is in Git. This is structurally the same blind spot as Incident #23, where the Helm release vanished and Argo CD rebuilt the namespace and ingress but could not rebuild the Helm-managed resources. Before real course content exists, this needs a `mysqldump` + PVC backup routine. GitOps guarantees the platform can be rebuilt; it guarantees nothing about the content on it.

### Interview talking points

1. **Configuration override beats data migration.** The textbook WordPress domain move edits the database. Overriding via `wp-config.php` constants achieves the same result while leaving the data untouched — which converts a risky, manual, forward-only migration into a declarative change that `git revert` undoes completely. When a system stores config in a database, look for a config-layer override before reaching for SQL.
2. **Know where TLS actually terminates.** The redirect loop is not a WordPress bug; it is the application correctly reasoning from incorrect information. Anything behind a TLS-terminating proxy must be told the original scheme via `X-Forwarded-Proto`, and must be configured to trust it. This applies to WordPress, Django, Rails, Grafana and Argo CD alike.
3. **Design changes so that rollback is structurally safe.** Adding a new file and commenting out one line means the revert path touches no working configuration. That is a deliberate choice: reversibility is a property you design in, not something you hope for during an incident.
4. **Understand your trigger paths.** Knowing the CI workflow filtered on `terraform/**` and `ansible/**` meant knowing in advance that this change could not trip the failing pipeline. Path filters are a blast-radius control, not just a speed optimisation.
5. **GitOps reconciles declarations, not content.** A recurring lesson from this cluster: Argo CD restores what is described in Git. Helm release state (Incident #23) and WordPress content (this change) both live outside Git and both need their own recovery path.

---

## Next Steps: Secrets Management Options

### Context

All secrets currently live in `.env` on the local machine. Docker Compose injects them as environment variables into the Terraform and Ansible containers. Nothing sensitive is committed to Git — this is correct.

**The gap this creates:** If a CI pipeline (e.g. GitHub Actions) needs to run `docker compose up` or Ansible directly, there is no safe way to inject `.env` into it without hardcoding secrets in workflow YAML or GitHub repository secrets for every variable. That approach does not scale and has no audit trail.

### Self-Hosting Options

| Option | Notes |
|--------|-------|
| **HashiCorp Vault** | The original. Kubernetes Helm deployment, raft storage (no external DB). Most features, steepest learning curve. BSL license since 2023. |
| **OpenBao** | Community fork of Vault after the BSL change. Drop-in replacement, MPL-2.0 license. Best choice if you want Vault but fully open source. |
| **Infisical** | Modern UI, easier setup, built-in K8s operator. Good docs. Slightly less mature than Vault. |
| **Doppler** | SaaS-first, self-hosted option is enterprise only. Not worth it for homelab. |
| **SOPS + age** | Not a server — encrypts secrets files with an age key pair. Commit encrypted secrets to Git. Argo CD decrypts via SOPS plugin. No new infrastructure. |

### Recommended Path

**Short term — SOPS + age:**
Encrypt `.env` secrets, commit encrypted file to Git. Argo CD decrypts at apply time using a key stored as a K8s secret. CI pipelines receive the same key from a GitHub Actions secret (one secret, not twenty).

**Long term — OpenBao + External Secrets Operator:**
```
OpenBao (in-cluster) → External Secrets Operator → K8s secrets
.env only needed once to bootstrap OpenBao on first deploy
```
External Secrets Operator watches OpenBao and keeps K8s secrets in sync. Application manifests reference K8s secrets as normal — no app changes needed. Secrets are rotatable without redeploying.

### Interview Talking Point

The `.env` pattern is a valid starting point for a homelab — it keeps secrets off Git and keeps the pipeline simple. The limitation appears the moment you introduce CI or multiple operators. Vault/OpenBao solves this by making secrets addressable by path and policy rather than by file location. The External Secrets Operator bridges Vault and Kubernetes — pods consume standard K8s secrets, and Vault is the source of truth. This is the same pattern used in production GitOps deployments at scale.
