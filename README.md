# MicroK8s DevOps Demo — v2

A production-style local Kubernetes project using MicroK8s on constrained
hardware (2-core CPU, 4 GB RAM per node, LAN-only, no cloud services).

**v2 changes from v1:**
- `install.sh` now creates `hosts.toml` on the control-plane node automatically
- `install.sh` optionally SSHs into the worker to configure `hosts.toml` there too
- Hostname-independent: no assumption that Node1 is called "node1" — uses `$(hostname)`
- New `scripts/setup-worker-node.sh` for standalone worker configuration
- Timeout increased to 5 min (from 3 min) for slow hardware
- Registry pod readiness check added before image push

---

## File Structure

```
microk8s-devops-demo/
├── app/                          Flask webapp (multi-stage Docker, non-root)
├── charts/webapp/                Helm chart (soft spreading, Downward API)
├── manifests/postgres-lowram.yaml  PostgreSQL (low-RAM tuned, hostpath PVC)
├── scripts/
│   ├── install.sh                Full automated setup (run on Node1)
│   ├── deploy-local.sh           Quick rebuild after code changes
│   ├── setup-worker-node.sh      Run on the worker to configure hosts.toml
│   ├── setup-dashboard.sh
│   ├── setup-observability.sh
│   └── setup-argocd.sh
├── cluster/README.md             2-node guide + hosts.toml explanation
├── argocd/app.yaml               GitOps Application manifest
├── .github/workflows/            SSH-based CI/CD pipeline
└── docs/                         Architecture, RAM budget, demo script, manual
```

---

## Before Re-running install.sh (Cleanup Steps)

If a previous install attempt failed, clean up first:

```bash
# 1. Remove the failed Helm release
microk8s helm3 uninstall webapp -n default 2>/dev/null || true

# 2. Remove PostgreSQL resources
#    (use the patched file if it exists, else the original)
microk8s kubectl delete -f /tmp/postgres-lowram-patched.yaml 2>/dev/null || \
microk8s kubectl delete -f manifests/postgres-lowram.yaml    2>/dev/null || true

# 3. Delete the PVC so Postgres gets a clean data directory
microk8s kubectl delete pvc postgres-pvc -n default 2>/dev/null || true

# 4. Confirm everything is gone
microk8s kubectl get all,pvc -n default
# Should show: No resources found.
```

---

## Quick Start (single node)

```bash
chmod +x scripts/*.sh
./scripts/install.sh
```

## Quick Start (two nodes — auto-configures worker)

```bash
chmod +x scripts/*.sh
NODE2_IP=192.168.0.101 NODE2_USER=johan ./scripts/install.sh
```

The script auto-detects `NODE1_IP` and `NODE1_HOSTNAME` from the machine it
runs on — no need to hardcode them, regardless of what your hostnames are.

---

## Worker Node Setup (if not using NODE2_IP auto-config)

Run this **on the worker node** before deploying:

```bash
NODE1_IP=192.168.0.102 ./scripts/setup-worker-node.sh
```

Then on Node1, restart the deployment so pods retry pulling:

```bash
microk8s kubectl rollout restart deployment/webapp -n default
```

---

See [`docs/README.md`](docs/README.md) for the full deployment manual.
