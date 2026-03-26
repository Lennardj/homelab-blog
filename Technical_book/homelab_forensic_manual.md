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

## NOTE FOR CLAUDE — READ THIS BEFORE PROCESSING TRANSCRIPTS

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
