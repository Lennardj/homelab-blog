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

*Waiting for transcript files. Document will be fully populated once all history is provided.*
