# Homelab Project Forensic Manual & Interview Study Guide

**Author:** Lennard John
**Project:** Automated WordPress + Monitoring deployment on Proxmox
**Status:** 🔴 Awaiting chat history files — ToC and content will be populated once all transcripts are provided.

---

## How This Document Was Built

This manual is reconstructed from real project chat history across multiple LLM sessions. Every command, error, config value, and architectural decision mentioned in those transcripts is captured here — including mistakes, wrong turns, and the reasoning behind each fix.

It is intended as:
- A **forensic record** of the project from scratch to production
- An **interview study guide** — every section answers "why did you do it that way?"
- A **runbook** for repeating or extending the deployment

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

## Planned Table of Contents (Draft — will be expanded from transcripts)

### Part 1: Project Architecture & Decisions
- 1.1 Project Overview and Goals
- 1.2 Tool Selection Rationale (why each tool vs. alternatives)
- 1.3 Final Architecture Diagram

### Part 2: Infrastructure Layer (Proxmox + Terraform)
- 2.1 Proxmox Setup
  - 2.1.1 Selection Rationale
  - 2.1.2 Cloud-Init Template Configuration
  - 2.1.3 Failure Log
  - 2.1.4 Security & Hardening
- 2.2 Terraform
  - 2.2.1 Selection Rationale
  - 2.2.2 Provider Configuration (Proxmox + Cloudflare)
  - 2.2.3 VM Provisioning (`main.tf` breakdown)
  - 2.2.4 Variables & Secrets (`variables.tf`, `.env`)
  - 2.2.5 Outputs (`outputs.tf`)
  - 2.2.6 Failure Log (provider version issues, 409 conflicts, TF_VAR naming)
  - 2.2.7 Security & Hardening

### Part 3: Kubernetes Cluster Bootstrap (Ansible + kubeadm)
- 3.1 Ansible
  - 3.1.1 Selection Rationale
  - 3.1.2 Playbook Structure and Execution Order
  - 3.1.3 Inventory Generation (`build_inventory.py`)
  - 3.1.4 Failure Log (apt lock, grep pipe bug, relative paths, KUBECONFIG)
  - 3.1.5 Security & Hardening
- 3.2 kubeadm Cluster Initialisation
  - 3.2.1 Prerequisites (swap, kernel modules, sysctl, containerd)
  - 3.2.2 Control Plane Init
  - 3.2.3 Worker Join
  - 3.2.4 Calico CNI
  - 3.2.5 Failure Log

### Part 4: Kubernetes Platform Services
- 4.5 cert-manager
  - 4.5.1 Selection Rationale (DNS-01 vs HTTP-01, why Cloudflare)
  - 4.5.2 ClusterIssuer Configuration
  - 4.5.3 Certificate Lifecycle
  - 4.5.4 Failure Log
- 4.1 NGINX Ingress Controller
  - 4.1.1 Selection Rationale
  - 4.1.2 Configuration Breakdown
  - 4.1.3 Failure Log
- 4.2 MetalLB
  - 4.2.1 Selection Rationale
  - 4.2.2 IPAddressPool + L2Advertisement Config
  - 4.2.3 Failure Log
- 4.3 Local Path Provisioner
- 4.4 Metrics Server

### Part 5: Application Deployments
- 5.1 WordPress + MariaDB
  - 5.1.1 Manifest Breakdown
  - 5.1.2 Persistent Volumes
  - 5.1.3 Secrets Injection
  - 5.1.4 Liveness + Readiness Probes
  - 5.1.5 Failure Log
- 5.2 Prometheus + Grafana (kube-prometheus-stack)
  - 5.2.1 Helm Values Breakdown
  - 5.2.2 Grafana Ingress
  - 5.2.3 Failure Log

### Part 6: Cloudflare Integration
- 6.1 Zero Trust Tunnel
  - 6.1.1 Selection Rationale (vs. port forwarding, vs. VPN)
  - 6.1.2 Provider v4 → v5 Migration (what broke, what changed)
  - 6.1.3 Token Auth vs. Credentials-File Auth
  - 6.1.4 Ingress Rules via API (`terraform_data`)
  - 6.1.5 Failure Log (409 conflict, 403 DNS, unsupported attributes)
- 6.2 DNS Records

### Part 7: CI/CD Pipeline (Docker Compose)
- 7.1 Pipeline Design (`docker-compose.yaml`)
- 7.2 Terraform Container (`run.sh`)
- 7.3 Ansible Container (`build_inventory.py`)
- 7.4 Secrets Flow (`.env` → containers)
- 7.5 Failure Log

### Part 8: Planned Additions
- 8.1 Argo CD (GitOps)
- 8.2 GitHub Actions (CI)
- 8.3 Secrets Management (External Secrets / Vault)
- 8.4 Alerting (Prometheus AlertManager)
- 8.5 Day-2 Operations

### Part 9: Source Reference Index
- 9.1 Docker Base Images
- 9.2 Kubernetes Application Images
- 9.3 Raw Manifest URLs (kubectl apply -f)
- 9.4 Helm Chart Repositories
- 9.5 Terraform Providers
- 9.6 External APIs

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
