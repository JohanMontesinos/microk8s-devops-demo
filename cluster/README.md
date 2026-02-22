# Two-Node MicroK8s Cluster Guide

This guide covers joining a worker node, explains the `hosts.toml` requirement
that trips up almost every fresh MicroK8s install, and documents how to handle
the case where your machine hostnames do not match the logical "Node1 / Node2"
terminology used in these docs.

---

## ⚠ Hostname vs Role — Read This First

The labels "Node1" and "Node2" in this project refer to **roles**, not hostnames:

| Logical role | What it runs | Hostname might be... |
|---|---|---|
| Node1 | Control plane + worker | `jnode2`, `server1`, `mypc` — anything |
| Node2 | Worker only | `jnode1`, `worker`, `rpi4` — anything |

**The scripts never assume a specific hostname.** `install.sh` calls `hostname`
at runtime to detect the real name and patches the Postgres `nodeSelector`
accordingly. Always run `install.sh` on whichever machine is your control plane.

---

## 1. Why Two Nodes?

| Benefit | Detail |
|---|---|
| RAM distribution | Each node has 4 GB; spreading workloads prevents OOM on one node |
| Resilience | Worker keeps serving pods if the control-plane node reboots |
| Demo value | Proves topology spreading — pods land on different physical machines |

---

## 2. Required Firewall Ports

Open on **both nodes**:

```bash
sudo ufw allow 16443/tcp   # MicroK8s API server
sudo ufw allow 10255/tcp   # kubelet read-only
sudo ufw allow 25000/tcp   # MicroK8s cluster-agent (used by add-node / join)
sudo ufw allow 12379/tcp   # etcd
sudo ufw allow 10000/tcp   # kubelet
sudo ufw allow 10001/tcp   # kubelet
sudo ufw allow 4789/udp    # Flannel VXLAN overlay
sudo ufw reload
```

Open on **Node1 only** (so worker can pull images):

```bash
sudo ufw allow 32000/tcp   # MicroK8s built-in registry
sudo ufw reload
```

---

## 3. Joining the Worker Node

**On Node1** (your control-plane machine):

```bash
microk8s add-node
# Prints something like:
# microk8s join 192.168.0.102:25000/abc123/def456 --worker
```

**On Node2** (worker machine) — install MicroK8s first, then join:

```bash
sudo snap install microk8s --classic --channel=1.28/stable
sudo usermod -aG microk8s $USER
newgrp microk8s

# Paste the exact command from `microk8s add-node` output:
microk8s join 192.168.0.102:25000/abc123/def456 --worker
```

`--worker` means Node2 will not run etcd or the API server — saving ~300 MB RAM.

---

## 4. Verify

```bash
# Run on Node1:
microk8s kubectl get nodes -o wide
```

Expected:

```
NAME     STATUS   ROLES    AGE   VERSION   INTERNAL-IP
jnode2   Ready    <none>   10m   v1.28.x   192.168.0.102   ← Node1 (control plane)
jnode1   Ready    <none>   2m    v1.28.x   192.168.0.101   ← Node2 (worker)
```

Both must show `Ready` before deploying.

---

## 5. Why `localhost:32000` Fails on the Worker

When containerd on the **worker** tries to pull `localhost:32000/webapp:latest`,
it resolves `localhost` to the worker's own loopback address (`127.0.0.1`).
There is no registry on the worker's port 32000 — it only runs on Node1.
The pull fails immediately with `connection refused`.

**Fix:** always tag images as `NODE1_IP:32000/webapp:latest` using the real LAN
IP. The `install.sh` and Helm `--set` flags already enforce this.

---

## 6. Why `hosts.toml` Is Required on EVERY Node

Even with the correct IP in the image tag, containerd still fails with:

```
http: server gave HTTP response to HTTPS client
```

This is because containerd defaults to HTTPS for all registries. The
`hosts.toml` file tells it to use plain HTTP for the specific registry address.

**This file is needed on the control-plane node too** — MicroK8s containerd is
separate from Docker and does not inherit Docker's `insecure-registries` setting.

### Create hosts.toml on the worker (Node2)

Option A — Use the dedicated script (easiest):

```bash
# Run on the worker node:
NODE1_IP=192.168.0.102 ./scripts/setup-worker-node.sh
```

Option B — Let install.sh do it automatically:

```bash
# Run on Node1 with NODE2_IP set:
NODE2_IP=192.168.0.101 NODE2_USER=johan ./scripts/install.sh
```

Option C — Manual steps on the worker:

```bash
NODE1_IP="192.168.0.102"    # replace with real Node1 IP
CERTS_DIR="/var/snap/microk8s/current/args/certs.d/${NODE1_IP}:32000"

sudo mkdir -p "$CERTS_DIR"
sudo tee "${CERTS_DIR}/hosts.toml" > /dev/null <<EOF
server = "http://${NODE1_IP}:32000"

[host."http://${NODE1_IP}:32000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF

sudo systemctl restart snap.microk8s.daemon-containerd
sleep 5

# Verify: should return {"repositories":["webapp"]}
curl -s http://${NODE1_IP}:32000/v2/_catalog
```

---

## 7. Spreading Behaviour Demo

```bash
# Scale to 4 replicas and watch placement in real time
microk8s kubectl scale deployment/webapp --replicas=4
watch -n1 "microk8s kubectl get pods -o wide --namespace=default"

# Expected with 2 nodes (NODE column shows real hostnames):
#   webapp-xxx-aaa   Running   jnode2   ← Node1
#   webapp-xxx-bbb   Running   jnode1   ← Node2
#   webapp-xxx-ccc   Running   jnode2
#   webapp-xxx-ddd   Running   jnode1

# Scale back
microk8s kubectl scale deployment/webapp --replicas=2
```

---

## 8. HA Warning — Not Recommended on 4 GB RAM

MicroK8s HA requires etcd on all 3 control-plane nodes (~250 MB each).
On 4 GB nodes already running webapp, PostgreSQL, DNS, and ingress, this
causes OOMKills. Use 1-control-plane + 1-worker for this demo.

---

## 9. Node Responsibility Table

| Component | Node1 (control plane) | Node2 (worker) |
|---|---|---|
| API Server / etcd | Yes | No |
| CoreDNS | Yes | No |
| Nginx Ingress | Yes | No |
| Registry :32000 | Yes | No |
| PostgreSQL | Yes (pinned by nodeSelector to real hostname) | No |
| webapp Pods | Yes | Yes (soft spread) |
| ArgoCD | Yes | No |

---

## 10. Troubleshooting: ImagePullBackOff on Worker

```bash
# Step 1 — identify pod and read events
microk8s kubectl get pods -o wide -n default
microk8s kubectl describe pod <name> -n default | grep -A10 "Events:"

# Step 2 — check hosts.toml exists on the worker
ssh WORKER_USER@WORKER_IP \
  "ls /var/snap/microk8s/current/args/certs.d/NODE1_IP:32000/hosts.toml"
# Missing -> run setup-worker-node.sh

# Step 3 — test registry reachability from the worker
ssh WORKER_USER@WORKER_IP "curl -s http://NODE1_IP:32000/v2/_catalog"
# Connection refused -> Node1 firewall blocking 32000

# Step 4 — fix Node1 firewall if needed
sudo ufw allow 32000/tcp && sudo ufw reload

# Step 5 — after fixing, force a new pull
microk8s kubectl rollout restart deployment/webapp -n default
microk8s kubectl get pods -o wide -n default -w
```
