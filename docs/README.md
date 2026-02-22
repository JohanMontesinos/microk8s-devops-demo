# MicroK8s DevOps Demo — Full Deployment Manual

> **Audience:** junior DevOps engineers with basic Linux knowledge.
> No prior MicroK8s experience required. Every command is explained.

---

## Table of Contents

- [Part A — Prerequisites](#part-a--prerequisites)
- [Part B — Single-Node Quick Start](#part-b--single-node-quick-start)
- [Part C — Two-Node Cluster Setup](#part-c--two-node-cluster-setup)
- [Part D — GitOps Setup (Gitea + ArgoCD)](#part-d--gitops-setup-gitea--argocd)
- [Part E — Observability](#part-e--observability)
- [Part F — CI/CD (GitHub Actions)](#part-f--cicd-github-actions)
- [MicroK8s Tuning for Low-Resource Nodes](#microk8s-tuning-for-low-resource-nodes)
- [Troubleshooting](#troubleshooting)

---

## Part A — Prerequisites

Install the following on **each node** (Node1 and Node2):

```bash
sudo apt-get update
sudo apt-get install -y curl git docker.io

# Start Docker and add your user to the docker group (avoids needing sudo)
sudo systemctl enable --now docker
sudo usermod -aG docker $USER

# Apply the group change without logging out
newgrp docker

# Verify Docker works correctly
docker run --rm hello-world
```

Also confirm your nodes can reach each other over the LAN:

```bash
# From Node2, ping Node1
ping -c4 NODE1_IP

# From Node1, ping Node2
ping -c4 NODE2_IP
```

---

## Part B — Single-Node Quick Start

The fastest path to a running app on a single machine:

```bash
# Clone the repository
git clone <this-repo> microk8s-devops-demo
cd microk8s-devops-demo

# Make all scripts executable
chmod +x scripts/*.sh

# Run the full automated installer
./scripts/install.sh
```

`install.sh` performs all of the following automatically:

1. Installs MicroK8s 1.28 via snap
2. Enables the `dns`, `storage`, `ingress`, `registry`, and `helm3` addons
3. Configures Docker to allow the local HTTP registry (insecure-registries)
4. Patches the PostgreSQL manifest with the real node hostname
5. Deploys PostgreSQL and waits for it to be ready
6. Builds the Flask webapp Docker image and pushes it to the local registry
7. Deploys the webapp via Helm and waits for rollout to complete
8. Prints a summary with the app URL and useful commands

When it finishes, open `http://NODE1_IP/` in a browser on your LAN.

---

## Part C — Two-Node Cluster Setup

See `cluster/README.md` for the complete walkthrough. Key steps:

1. Open the required firewall ports on both nodes (section 2)
2. Run `microk8s add-node` on Node1 to generate a join token
3. Run `microk8s join ... --worker` on Node2
4. Create `hosts.toml` on Node2 so it can pull images from Node1's HTTP registry (section 6)
5. Verify with `kubectl get nodes` — both nodes should show `Ready`

---

## Part D — GitOps Setup (Gitea + ArgoCD)

GitOps means the cluster state is always derived from Git. Any change pushed to
the repository is automatically applied to the cluster by ArgoCD.

### Step 1 — Start Gitea (local Git server)

Run Gitea as a Docker container on Node1. It requires no external internet
access after the image is downloaded.

```bash
# Pull and start Gitea (binds to port 3000 HTTP and 2222 SSH)
docker run -d \
  --name gitea \
  --restart unless-stopped \
  -p 3000:3000 \
  -p 2222:22 \
  -v ~/gitea-data:/data \
  gitea/gitea:1.21

# Open the Gitea setup wizard in your browser:
# http://NODE1_IP:3000
#
# Settings to use in the wizard:
#   Database: SQLite (simplest, no separate DB server needed)
#   Site URL: http://NODE1_IP:3000
#   Create an admin user when prompted
```

### Step 2 — Push this repository to Gitea

```bash
cd microk8s-devops-demo

# Initialize git if you cloned without git history
git init
git add .
git commit -m "Initial commit"

# Add Gitea as a remote (replace NODE1_IP and YOUR_USER)
git remote add gitea http://NODE1_IP:3000/YOUR_USER/microk8s-devops-demo.git

# Create the repository in Gitea first (via the web UI), then push
git push gitea main
```

### Step 3 — Install ArgoCD

```bash
./scripts/setup-argocd.sh
# This installs ArgoCD, exposes it on NodePort 30443, and prints the admin password
```

### Step 4 — Connect ArgoCD to Gitea

```bash
# Edit argocd/app.yaml and replace both NODE1_IP placeholders with the real IP
sed -i "s/NODE1_IP/$(hostname -I | awk '{print $1}')/g" argocd/app.yaml

# Apply the Application manifest
microk8s kubectl apply -f argocd/app.yaml

# Verify ArgoCD picks it up (check the ArgoCD UI at https://NODE1_IP:30443)
microk8s kubectl -n argocd get applications
```

ArgoCD polls Gitea every 3 minutes. After any `git push` to the `charts/`
directory, the change is reflected in the cluster within ~3 minutes automatically.
ArgoCD also self-heals: if someone manually deletes a pod or edits a deployment,
ArgoCD restores the desired state.

---

## Part E — Observability

### Option 1: metrics-server (recommended)

Safe for 4 GB RAM nodes. Uses approximately 30 MB.

```bash
./scripts/setup-observability.sh
# or explicitly:
./scripts/setup-observability.sh metrics

# After install:
microk8s kubectl top nodes
microk8s kubectl top pods --namespace=default
```

### Option 2: kube-prometheus-stack (use with caution)

**Warning:** Prometheus + Grafana + AlertManager together consume 500–700 MB of
RAM. On a 4 GB node already running webapp pods, PostgreSQL, DNS, and the ingress
controller, this can push the node into memory pressure and cause OOMKill events.

Only install this if you have disabled other workloads or accepted the risk:

```bash
./scripts/setup-observability.sh prometheus
# The script will show a warning and ask for confirmation before proceeding

# Access Grafana after install:
microk8s kubectl -n monitoring port-forward svc/kube-prom-grafana 3000:80 &
# Open: http://localhost:3000
# Credentials: admin / prom-operator
```

---

## Part F — CI/CD (GitHub Actions)

The workflow in `.github/workflows/ci-microk8s-ssh.yml` triggers on every push
to `main` that changes files in `app/`, `charts/`, or `manifests/`.

It does NOT require a self-hosted runner on Node1. Instead, the hosted GitHub
Actions runner (ubuntu-latest) SSHs into Node1 to run the build and deploy steps
remotely.

### Required GitHub Secrets

Go to: **Settings → Secrets and Variables → Actions → New repository secret**

| Secret Name | Value |
|---|---|
| `NODE1_IP` | LAN IP of Node1 (e.g. `192.168.1.100`) |
| `NODE1_USER` | SSH username on Node1 |
| `NODE1_SSH_KEY` | Content of the CI private key (see below) |

### Generate the SSH Key Pair

```bash
# Run this on your laptop (not on Node1)
ssh-keygen -t ed25519 -f ~/.ssh/ci_key -N "" -C "github-actions-ci"

# Install the PUBLIC key on Node1 so the runner can authenticate
ssh-copy-id -i ~/.ssh/ci_key.pub NODE1_USER@NODE1_IP

# Copy the PRIVATE key content and paste it into the NODE1_SSH_KEY secret
cat ~/.ssh/ci_key
```

### How the Pipeline Works

1. The GitHub-hosted runner checks out the repository
2. It rsyncs changed `app/` and `charts/` directories to `~/microk8s-devops-demo/` on Node1
3. It SSHs into Node1 and runs `docker build`, `docker push`, then `helm upgrade`
4. The runner reports success or failure back to GitHub
5. No process runs persistently on Node1 — the SSH daemon (port 22) is the only
   requirement

---

## MicroK8s Tuning for Low-Resource Nodes

### Prevent snap auto-refresh during demos

Snap can auto-update MicroK8s in the background, interrupting your demo. Freeze
updates for 30 days:

```bash
sudo snap set system refresh.hold="$(date --date='30 days' +%Y-%m-%dT%H:%M:%S%:z)"
```

### Reduce API server request queue depth

The default queue sizes assume a large cluster. On a 2-core node, smaller queues
reduce memory overhead:

```bash
sudo tee -a /var/snap/microk8s/current/args/kube-apiserver <<EOF
--max-requests-inflight=50
--max-mutating-requests-inflight=25
EOF

sudo systemctl restart snap.microk8s.daemon-apiserver
```

### Monitor memory usage

```bash
# OS-level view
free -h

# Kubernetes-level view (requires metrics-server)
microk8s kubectl top nodes
microk8s kubectl top pods --all-namespaces --sort-by=memory
```

### Check for memory pressure events

```bash
# Look for OOMKill events in the last hour
sudo journalctl -k --since "1 hour ago" | grep -i oom
```

---

## Troubleshooting

| # | Symptom | Diagnosis Command | Fix |
|---|---|---|---|
| 1 | Pods stuck in `Pending` | `kubectl describe pod <name>` — look for "Insufficient memory" or "no PVC bound" | Reduce `resources.requests` in `values.yaml`, or check `kubectl get pvc` for Pending PVCs |
| 2 | Pod shows `OOMKilled` in Last State | `kubectl describe pod <name>` — check "Last State: OOMKilled" | Increase `resources.limits.memory` to `384Mi`, OR reduce gunicorn workers from 2 to 1 in Dockerfile |
| 3 | `ImagePullBackOff` on Node2 | `kubectl describe pod <name>` — look for TLS error or "connection refused" | Create `hosts.toml` on Node2 (see `cluster/README.md` Section 6) and restart containerd |
| 4 | Ingress returns 404 for all paths | `kubectl get ingress` — check ADDRESS column; `kubectl describe ing webapp` | Run `microk8s enable ingress`; verify `ingressClassName: nginx` matches the ingress controller |
| 5 | `docker push` fails with TLS error | Error: "server gave HTTP response to HTTPS client" | Add `NODE1_IP:32000` to `/etc/docker/daemon.json` under `insecure-registries`, then `sudo systemctl restart docker` |
| 6 | Postgres `CrashLoopBackOff` or empty DB after restart | `kubectl logs deploy/postgres` — "Permission denied" or "data directory is empty" | Verify `nodeSelector.kubernetes.io/hostname` in the manifest matches `kubectl get nodes` output exactly |
