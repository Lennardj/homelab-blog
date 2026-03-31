# Video Outline: "How to Over-Engineer a Blog"

## Project Context (for AI script generation)

This is a homelab project by Lennard John (Platform Engineer). The entire project deploys a WordPress blog on a 3-node Kubernetes cluster running on Proxmox, with full GitOps, monitoring, alerting, and zero-trust public access via Cloudflare Tunnel. The joke is that it's absurdly over-engineered for a simple blog — but it demonstrates production-grade platform engineering skills.

**Repo:** https://github.com/Lennardj/homelab-blog
**Domain:** lennardjohn.org
**Author:** Lennard John — Platform Engineer, YouTube: @mrjohnhomelab

### Tech Stack
- Proxmox VE (hypervisor on physical hardware)
- Terraform (provisions 3 VMs + Cloudflare tunnel + DNS)
- Ansible (bootstraps K8s cluster + deploys all apps via 9 playbooks)
- Kubernetes (kubeadm, 1 control plane + 2 workers)
- Calico CNI, MetalLB, NGINX Ingress, Local Path Provisioner
- WordPress + MariaDB (the blog itself)
- Prometheus + Grafana + AlertManager (monitoring + email alerts)
- Argo CD (GitOps — auto-syncs kubernetes/ directory on every git push)
- cert-manager + Let's Encrypt (automated TLS via DNS-01 challenge)
- Cloudflare Tunnel (zero-trust public access, no port forwarding)
- GitHub Actions + self-hosted runner on Proxmox (CI/CD pipeline)
- NetworkPolicy (MariaDB only accepts traffic from WordPress)
- Landing page at lennardjohn.org (terminal-style dark theme, served via nginx + ConfigMap)

### The Pipeline (one command)
```
docker compose up
  → Terraform creates 3 VMs on Proxmox + Cloudflare tunnel + DNS records
  → Ansible bootstraps Kubernetes cluster
  → Ansible deploys: cert-manager, Argo CD, Prometheus/Grafana, WordPress/MariaDB, cloudflared, landing page
  → Argo CD takes over for ongoing GitOps
```

### Public URLs
- https://lennardjohn.org (landing page)
- https://blog.lennardjohn.org (WordPress)
- https://grafana.lennardjohn.org (Grafana dashboards)
- https://argocd.lennardjohn.org (Argo CD UI)

---

## Section 1: Intro (30 seconds)

**Tone:** Self-deprecating, funny. You're in on the joke.

**What to say:**
- Open with: "I just wanted to write a blog."
- Quick montage/flash of all 4 live sites loading in a browser
- "So naturally, I built a 3-node Kubernetes cluster on bare metal with Terraform, Ansible, GitOps, monitoring, alerting, and zero-trust networking."
- "Here's how."

**Visuals needed:**
- Quick cuts of each site loading in a browser (lennardjohn.org, blog, grafana, argocd)
- Optional: meme or reaction image of "it's just a blog" vs the architecture diagram

---

## Section 2: Architecture Overview (2 minutes)

**What to say:**
- Walk through the full architecture from left to right
- "Everything starts with a single `.env` file and `docker compose up`"
- Explain the flow: Terraform provisions infrastructure, Ansible configures it, Argo CD maintains it
- "After the initial build, I never SSH into the cluster. Every change goes through Git."

**Key points to hit:**
- Proxmox is the hypervisor running on physical hardware at home
- Terraform creates 3 VMs (1 master, 2 workers) AND the Cloudflare tunnel AND DNS records — all in one apply
- Ansible runs 9 playbooks in sequence to bootstrap K8s and deploy everything
- Argo CD watches the GitHub repo and auto-syncs any changes to kubernetes/
- Cloudflare Tunnel provides public access with no port forwarding — zero-trust model
- GitHub Actions self-hosted runner on Proxmox triggers the pipeline on git push

**Visuals needed:**
- Architecture diagram showing the full flow:
```
.env → Docker Compose
         ├→ Terraform Container → Proxmox API (3 VMs) + Cloudflare API (tunnel + DNS)
         └→ Ansible Container → SSH into VMs → 9 playbooks → K8s cluster ready
                                                                    │
              GitHub ← git push ← Developer                        │
                │                                                   │
                ├→ GitHub Actions → runner-01 VM → docker compose up (CI/CD)
                │
                └→ Argo CD (in cluster) watches repo → auto-syncs kubernetes/
                                                                    │
              Browser → Cloudflare Edge → Tunnel → NGINX Ingress → Apps
                        (HTTPS)           (HTTP)    (routing)    (WordPress, Grafana, Argo CD, Landing)
```

---

## Section 3: The Code (2 minutes)

**What to say:**
- Show the GitHub repo in browser or VS Code
- Walk through the directory structure: terraform/, ansible/, kubernetes/, docker/, scripts/
- "The .env file is the only thing not in Git — it has all the credentials"
- Show .env structure (with values redacted/blurred)
- Show docker-compose.yaml — "Two containers: one runs Terraform, one runs Ansible. That's the entire pipeline."
- "Terraform writes output.json with VM IPs, Ansible reads it and builds the inventory automatically"

**Key files to show on screen:**
```
homelab-blog/
├── terraform/proxmox/     → main.tf, cloudflare.tf, variables.tf, outputs.tf
├── ansible/playbook/      → 9 playbooks (playbook.yml through deploy-landing.yml)
├── kubernetes/            → wordpress/, monitoring/, argocd/, cloudflared/, landing/, metallb/
├── docker/                → Dockerfiles + run.sh for terraform and ansible containers
├── scripts/               → build_inventory.py, sync-env.ps1, teardown.ps1
├── .github/workflows/     → deploy.yml (CI/CD)
├── docker-compose.yaml    → Orchestrates the pipeline
└── .env                   → All credentials (git-ignored)
```

**Visuals needed:**
- Screen recording of scrolling through repo in VS Code or GitHub
- Highlight/zoom on docker-compose.yaml showing the two services
- Show .env with values blurred

---

## Section 4: Live Demo — git push triggers CI (3-4 minutes)

**What to say:**
- "Let me show you what happens when I push a change"
- Make a small edit to a terraform file
- `git add`, `git commit`, `git push`
- Switch to GitHub Actions tab — show the workflow trigger
- "This is running on a self-hosted runner — a VM on the same Proxmox host. It has direct LAN access to everything."
- Fast-forward through the build with narration over key moments:
  - "Terraform is creating the VMs now..."
  - "SSH is up, Ansible is taking over..."
  - "Installing Kubernetes prerequisites, bootstrapping the cluster..."
  - "Deploying cert-manager, Argo CD, Prometheus, Grafana..."
  - "WordPress and MariaDB are going up..."
  - "Cloudflare tunnel is connecting..."
  - "Landing page is live..."
- "Total time: about 25 minutes from push to production"

**Visuals needed:**
- Screen recording of: terminal (git push) → GitHub Actions page → logs streaming
- Speed up the 20-25 min build to 2-3 min with key moments highlighted
- Optional: picture-in-picture of Proxmox UI showing VMs being created

---

## Section 5: Results (2-3 minutes)

**What to say:**
- SSH into the master node (or show kubectl from runner)
- `kubectl get nodes` — "3 nodes, all Ready"
- `kubectl get pods -A` — "Everything running across all namespaces"
- Open each site in browser:
  - lennardjohn.org — "My landing page, served from a Kubernetes ConfigMap. No Docker image build needed."
  - blog.lennardjohn.org — "WordPress, running on MariaDB, with automated TLS from Let's Encrypt"
  - grafana.lennardjohn.org — "Prometheus metrics — CPU, memory, pod status, everything"
  - argocd.lennardjohn.org — "All 4 apps synced and healthy. This is my GitOps control plane."

**Key kubectl outputs to show:**
```
$ kubectl get nodes
NAME             STATUS   ROLES           AGE   VERSION
k8s-master-01   Ready    control-plane   25m   v1.30.x
k8s-worker-1    Ready    <none>          24m   v1.30.x
k8s-worker-2    Ready    <none>          24m   v1.30.x

$ kubectl get pods -A
(all pods Running, all 1/1 or 2/2 Ready)
```

**Visuals needed:**
- Terminal showing kubectl output
- Browser tabs opening each site
- Argo CD UI showing all apps green/synced

---

## Section 6: GitOps Demo (2 minutes)

**What to say:**
- "Now that the cluster is running, I never need to SSH in again. Every change goes through Git."
- Open kubernetes/landing/configmap.yaml
- Make a visible change (e.g. change the role from "Platform Engineer" to "Over-Engineer" or add a new tag)
- `git add`, `git commit`, `git push`
- Switch to Argo CD UI — "Watch this. Argo CD detects the diff..."
- Show the sync happening in real time
- Refresh lennardjohn.org — "Change is live. No kubectl, no SSH, no Ansible. Just Git."

**Key point:** This does NOT trigger the CI pipeline (kubernetes/ path is not in the workflow trigger). Argo CD handles it directly — true GitOps.

**Visuals needed:**
- Split screen or quick cuts: VS Code edit → terminal push → Argo CD UI syncing → browser refresh showing change

---

## Section 7: Monitoring + Security (1 minute)

**What to say:**
- Show Grafana dashboard: "Prometheus scrapes metrics from every node and pod"
- Show node CPU/memory graphs, pod status panels
- "I have 7 alert rules. If a pod crashes, a node goes down, or memory spikes above 85% — I get an email."
- Show AlertManager rules in Grafana Alerting tab
- "On the security side — MariaDB has a NetworkPolicy. Only the WordPress pod can talk to it on port 3306. Nothing else in the cluster can reach the database."
- "And there are no ports open on my home router. Everything goes through a Cloudflare Tunnel — zero-trust."

**Alert rules to mention/show:**
| Alert | Fires when |
|---|---|
| PodCrashLooping | Pod restarts in last 10 min |
| PodNotReady | Pod not ready for 5 min |
| NodeNotReady | Node down for 2 min |
| NodeHighMemory | Memory > 85% for 5 min |
| NodeHighCPU | CPU > 85% for 5 min |
| NodeDiskPressure | Disk > 85% for 5 min |
| DeploymentReplicasMismatch | Desired ≠ ready replicas for 10 min |

**Visuals needed:**
- Grafana dashboard with live metrics
- Grafana Alerting page showing rule list
- Optional: show a test alert email on phone/screen

---

## Section 8: Outro (30 seconds)

**What to say:**
- Show the full architecture diagram one more time
- "All of this — from bare metal to live public website — from one `git push`"
- "The entire project is open source. Link in the description. Fork it, break it, build your own."
- "If you learned something, hit subscribe. I'm Lennard John, and yes, this is how I write a blog."

**Visuals needed:**
- Architecture diagram (same as section 2)
- GitHub repo link on screen
- Social links: YouTube, GitHub, LinkedIn, Dev.to

---

## Production Notes

### Before recording
```bash
# Switch all ingresses to production TLS (trusted certs)
sed -i 's/letsencrypt-staging/letsencrypt-prod/g' \
  kubernetes/wordpress/ingress.yaml \
  kubernetes/monitoring/grafana-ingress.yaml \
  kubernetes/argocd/ingress.yaml \
  kubernetes/landing/ingress.yaml
git add -p && git commit -m "Switch to prod TLS for video" && git push
```
Wait 60 seconds after deploy for cert-manager to issue trusted certificates.

### Recording tips
- Record the full CI build once, then speed it up in editing
- Use OBS or screen recorder with picture-in-picture for terminal + browser
- Keep a second monitor with Proxmox UI open to show VMs being created
- For the GitOps demo, have the Argo CD UI and browser open side by side
- Clear browser history/cache before recording to avoid "Not Secure" warnings from previous staging certs
- Clear Chrome HSTS cache: chrome://net-internals/#hsts → delete each domain

### Thumbnail ideas
- "How to Over-Engineer a Blog" text over the architecture diagram
- Split: simple WordPress logo on left, explosion of K8s/Terraform/Ansible logos on right
- Terminal screenshot with the landing page visible
