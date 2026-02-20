#!/usr/bin/env bash
# Uninstall the microk8s-devops-demo deployment completely.
#
# What this script REMOVES:
#   - Helm release: webapp
#   - Kubernetes resources: postgres Deployment, Service, Secret, PVC
#   - Local Docker image: NODE1_IP:32000/webapp:latest
#   - Registry image: webapp (deleted from the built-in registry)
#   - hosts.toml file created for the local registry
#   - Patched postgres manifest from /tmp
#
# What this script KEEPS:
#   - MicroK8s itself (running and ready for other deployments)
#   - All enabled addons (dns, storage, ingress, registry, helm3, etc.)
#   - Any other Helm releases or namespaces not created by this project
#   - Docker daemon config (insecure-registries entry is cleaned up safely)
#   - SSH keys, user config, snap packages
#
# Optional env vars:
#   NODE1_IP    — override auto-detected LAN IP
#   NODE2_IP    — if set, also cleans up hosts.toml on the worker via SSH
#   NODE2_USER  — SSH user for worker node (default: $USER)
#
# Usage:
#   ./uninstall.sh
#   NODE2_IP=192.168.0.101 NODE2_USER=johan ./uninstall.sh
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
CY='\033[0;36m'; GR='\033[0;32m'; YW='\033[0;33m'; RD='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${CY}[INFO]${NC}  $*"; }
success() { echo -e "${GR}[OK]${NC}    $*"; }
warn()    { echo -e "${YW}[WARN]${NC}  $*"; }
skip()    { echo -e "       (skipped — $*)"; }
die()     { echo -e "${RD}[ERROR]${NC} $*" >&2; exit 1; }

# ── Detect environment ────────────────────────────────────────────────────────
NODE1_IP="${NODE1_IP:-$(hostname -I | awk '{print $1}')}"
NODE2_IP="${NODE2_IP:-}"
NODE2_USER="${NODE2_USER:-$USER}"
REGISTRY="${NODE1_IP}:32000"

[[ -z "$NODE1_IP" ]] && die "Cannot detect NODE1_IP. Set it: NODE1_IP=x.x.x.x ./uninstall.sh"

echo ""
echo -e "${RD}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RD}║              microk8s-devops-demo — UNINSTALL                    ║${NC}"
echo -e "${RD}╠══════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${RD}║  This will remove all project resources from the cluster.        ║${NC}"
echo -e "${RD}║  MicroK8s itself will remain running.                            ║${NC}"
echo -e "${RD}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
info "Node1 IP       : ${NODE1_IP}"
info "Node1 hostname : $(hostname)"
[[ -n "$NODE2_IP" ]] && info "Worker node IP : ${NODE2_IP} (user: ${NODE2_USER})"
echo ""

read -r -p "Proceed with uninstall? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo ""

# ── 1. Remove Helm release (webapp) ──────────────────────────────────────────
info "Removing Helm release 'webapp' ..."
if microk8s helm3 status webapp -n default &>/dev/null; then
    microk8s helm3 uninstall webapp -n default
    success "Helm release 'webapp' removed."
else
    skip "Helm release 'webapp' not found"
fi

# ── 2. Remove PostgreSQL Kubernetes resources ─────────────────────────────────
info "Removing PostgreSQL Deployment ..."
if microk8s kubectl get deployment postgres -n default &>/dev/null; then
    microk8s kubectl delete deployment postgres -n default
    success "Postgres Deployment deleted."
else
    skip "Postgres Deployment not found"
fi

info "Removing PostgreSQL Service ..."
if microk8s kubectl get service postgres-service -n default &>/dev/null; then
    microk8s kubectl delete service postgres-service -n default
    success "Postgres Service deleted."
else
    skip "Postgres Service not found"
fi

info "Removing PostgreSQL Secret ..."
if microk8s kubectl get secret postgres-secret -n default &>/dev/null; then
    microk8s kubectl delete secret postgres-secret -n default
    success "Postgres Secret deleted."
else
    skip "Postgres Secret not found"
fi

info "Removing PostgreSQL PVC ..."
if microk8s kubectl get pvc postgres-pvc -n default &>/dev/null; then
    microk8s kubectl delete pvc postgres-pvc -n default
    # PVC deletion can take a moment — wait for it to fully unbind
    echo "         Waiting for PVC to be fully released ..."
    timeout 60 bash -c \
        'until ! microk8s kubectl get pvc postgres-pvc -n default &>/dev/null; do sleep 2; done' \
        || warn "PVC deletion timed out — it may still be terminating."
    success "Postgres PVC deleted."
else
    skip "Postgres PVC not found"
fi

# ── 3. Remove ArgoCD (if installed) ──────────────────────────────────────────
# Deleting the entire namespace is the cleanest way — it removes all ArgoCD
# CRDs, deployments, services, secrets, and Application resources in one shot.
info "Checking for ArgoCD namespace ..."
if microk8s kubectl get namespace argocd &>/dev/null; then
    info "Removing ArgoCD namespace and all its resources ..."
    microk8s kubectl delete namespace argocd
    echo "         Waiting for argocd namespace to terminate ..."
    timeout 120 bash -c \
        'until ! microk8s kubectl get namespace argocd &>/dev/null; do sleep 3; done' \
        || warn "ArgoCD namespace still terminating — may take a moment longer."
    success "ArgoCD removed."
else
    skip "ArgoCD namespace not found"
fi

# ── 5. Clean up any leftover pods (e.g. stuck Terminating) ───────────────────
info "Checking for any stuck project pods ..."
STUCK=$(microk8s kubectl get pods -n default \
    --field-selector=status.phase!=Running \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
if [[ -n "$STUCK" ]]; then
    warn "Force-deleting stuck pods: ${STUCK}"
    for pod in $STUCK; do
        microk8s kubectl delete pod "$pod" -n default --grace-period=0 --force 2>/dev/null || true
    done
    success "Stuck pods removed."
else
    skip "no stuck pods found"
fi

# ── 4. Delete webapp image from the built-in registry ────────────────────────
# The registry stores images as blobs. We use the registry API to delete
# the manifest, which frees up disk space on Node1.
info "Deleting webapp image from registry ${REGISTRY} ..."
DIGEST=$(curl -s \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    "http://${REGISTRY}/v2/webapp/manifests/latest" \
    -I 2>/dev/null | grep -i docker-content-digest | awk '{print $2}' | tr -d '\r' || true)

if [[ -n "$DIGEST" ]]; then
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        -X DELETE "http://${REGISTRY}/v2/webapp/manifests/${DIGEST}" || true)
    if [[ "$HTTP_STATUS" == "202" || "$HTTP_STATUS" == "200" ]]; then
        success "Registry image deleted (digest: ${DIGEST:0:24}...)."
    else
        warn "Registry delete returned HTTP ${HTTP_STATUS} — image may need manual cleanup."
        warn "Run: curl -X DELETE http://${REGISTRY}/v2/webapp/manifests/${DIGEST}"
    fi
else
    skip "webapp image not found in registry"
fi

# ── 5. Remove local Docker image ──────────────────────────────────────────────
info "Removing local Docker image ${REGISTRY}/webapp:latest ..."
if docker image inspect "${REGISTRY}/webapp:latest" &>/dev/null; then
    docker rmi "${REGISTRY}/webapp:latest"
    success "Local Docker image removed."
else
    skip "Docker image not found locally"
fi

# ── 6. Remove hosts.toml on THIS node ────────────────────────────────────────
HOSTS_TOML="/var/snap/microk8s/current/args/certs.d/${NODE1_IP}:32000/hosts.toml"
CERTS_DIR="/var/snap/microk8s/current/args/certs.d/${NODE1_IP}:32000"
info "Removing hosts.toml on this node ..."
if [[ -f "$HOSTS_TOML" ]]; then
    sudo rm -f "$HOSTS_TOML"
    sudo rmdir "$CERTS_DIR" 2>/dev/null || true
    sudo systemctl restart snap.microk8s.daemon-containerd
    success "hosts.toml removed and containerd restarted."
else
    skip "hosts.toml not found at ${HOSTS_TOML}"
fi

# ── 7. Remove hosts.toml on the worker node (if NODE2_IP provided) ───────────
if [[ -n "$NODE2_IP" ]]; then
    info "Removing hosts.toml on worker node ${NODE2_IP} ..."
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "${NODE2_USER}@${NODE2_IP}" bash -s "${NODE1_IP}" <<'REMOTE'
set -euo pipefail
NODE1_IP="$1"
HOSTS_TOML="/var/snap/microk8s/current/args/certs.d/${NODE1_IP}:32000/hosts.toml"
CERTS_DIR="/var/snap/microk8s/current/args/certs.d/${NODE1_IP}:32000"
if [[ -f "$HOSTS_TOML" ]]; then
    sudo rm -f "$HOSTS_TOML"
    sudo rmdir "$CERTS_DIR" 2>/dev/null || true
    sudo systemctl restart snap.microk8s.daemon-containerd
    echo "[worker] hosts.toml removed and containerd restarted."
else
    echo "[worker] hosts.toml not found — nothing to remove."
fi
REMOTE
    success "Worker node ${NODE2_IP} cleaned up."
else
    warn "NODE2_IP not set — skipping worker cleanup."
    echo "         To clean up the worker manually, run ON jnode1:"
    printf "           sudo rm -f /var/snap/microk8s/current/args/certs.d/%s:32000/hosts.toml\n" "${NODE1_IP}"
    echo  "           sudo systemctl restart snap.microk8s.daemon-containerd"
fi

# ── 8. Remove insecure-registries entry from Docker daemon.json ───────────────
info "Cleaning up Docker daemon insecure-registries entry ..."
DAEMON_JSON=/etc/docker/daemon.json
if [[ -f "$DAEMON_JSON" ]]; then
    sudo python3 - <<PYEOF
import json, sys
path = "$DAEMON_JSON"
try:
    cfg = json.load(open(path))
except Exception:
    sys.exit(0)
regs = cfg.get("insecure-registries", [])
entry = "$REGISTRY"
if entry in regs:
    regs.remove(entry)
    cfg["insecure-registries"] = regs
    # If the list is now empty remove the key entirely to keep daemon.json clean
    if not cfg["insecure-registries"]:
        del cfg["insecure-registries"]
    json.dump(cfg, open(path, "w"), indent=2)
    print("  Removed ${REGISTRY} from insecure-registries.")
else:
    print("  Entry not found — nothing to remove.")
PYEOF
    sudo systemctl restart docker
    success "Docker daemon.json cleaned up."
else
    skip "daemon.json not found"
fi

# ── 9. Remove patched manifest from /tmp ─────────────────────────────────────
info "Removing temporary patched manifest ..."
if [[ -f /tmp/postgres-lowram-patched.yaml ]]; then
    rm -f /tmp/postgres-lowram-patched.yaml
    success "Removed /tmp/postgres-lowram-patched.yaml"
else
    skip "no patched manifest found in /tmp"
fi

# ── 10. Final cluster state ───────────────────────────────────────────────────
echo ""
info "Final cluster state (should show only service/kubernetes):"
microk8s kubectl get all,pvc -n default
echo ""

echo -e "${GR}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                  ✅ UNINSTALL COMPLETE                           ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  All project resources have been removed.                        ║"
echo "║  MicroK8s is still running and ready for other deployments.      ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  To verify MicroK8s is healthy:                                  ║"
echo "║    microk8s status                                               ║"
echo "║    microk8s kubectl get nodes                                    ║"
echo "║                                                                  ║"
echo "║  To reinstall this project:                                      ║"
echo "║    ./scripts/install.sh                                          ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
