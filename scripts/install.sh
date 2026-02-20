#!/usr/bin/env bash
# Full automated setup: MicroK8s, addons, registry, hosts.toml, Postgres, webapp.
#
# IMPORTANT — Hostname independence:
#   This script detects the real hostname of the node it runs on and uses it
#   for the Postgres nodeSelector. It does NOT assume the control-plane node
#   is called "node1", "jnode1", or anything else.
#
# OPTIONAL env vars you can set before running:
#   NODE1_IP    — override auto-detected LAN IP  (default: hostname -I | awk '{print $1}')
#   NODE2_IP    — set this to auto-configure hosts.toml on the worker node via SSH
#   NODE2_USER  — SSH user on the worker node    (default: same as current $USER)
#
# Examples:
#   ./install.sh
#   NODE2_IP=192.168.0.101 NODE2_USER=johan ./install.sh
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
CY='\033[0;36m'; GR='\033[0;32m'; YW='\033[0;33m'; RD='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${CY}[INFO]${NC}  $*"; }
success() { echo -e "${GR}[OK]${NC}    $*"; }
warn()    { echo -e "${YW}[WARN]${NC}  $*"; }
die()     { echo -e "${RD}[ERROR]${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Auto-detect identity of THIS node (the control-plane / Node1) ─────────────
# We use the real hostname returned by `hostname`, NOT an assumed name.
# This means the script works correctly even if the control-plane machine is
# called jnode2, worker1, myserver, or anything else.
NODE1_IP="${NODE1_IP:-$(hostname -I | awk '{print $1}')}"
NODE1_HOSTNAME="$(hostname)"
NODE2_IP="${NODE2_IP:-}"
NODE2_USER="${NODE2_USER:-$USER}"

[[ -z "$NODE1_IP" ]] && die "Cannot detect NODE1_IP. Set it manually: NODE1_IP=x.x.x.x ./install.sh"

info "Control-plane node IP       : ${NODE1_IP}"
info "Control-plane node hostname : ${NODE1_HOSTNAME}"
[[ -n "$NODE2_IP" ]] && info "Worker node IP              : ${NODE2_IP} (user: ${NODE2_USER})"

REGISTRY="${NODE1_IP}:32000"

# ── 1. Install MicroK8s if missing ────────────────────────────────────────────
if ! command -v microk8s &>/dev/null; then
  info "Installing MicroK8s 1.28/stable via snap ..."
  sudo snap install microk8s --classic --channel=1.28/stable
  sudo usermod -aG microk8s "$USER"
  mkdir -p ~/.kube
  exec sg microk8s "$(realpath "$0")" "$@"
fi

info "Waiting for MicroK8s to be ready ..."
microk8s status --wait-ready --timeout 120

# ── 2. Enable required addons ─────────────────────────────────────────────────
info "Enabling addons: dns storage ingress registry helm3 ..."
microk8s enable dns storage ingress registry helm3
sleep 15

info "Waiting for registry pod to be Ready ..."
microk8s kubectl wait pod \
  -l app=registry \
  -n container-registry \
  --for=condition=Ready \
  --timeout=120s

# ── 3. Configure Docker insecure registry ─────────────────────────────────────
# Without this, `docker push NODE1_IP:32000/...` fails with a TLS error.
info "Configuring Docker insecure-registry: ${REGISTRY} ..."
if ! command -v docker &>/dev/null; then
  warn "Docker not found — installing docker.io ..."
  sudo apt-get update -qq && sudo apt-get install -y -qq docker.io
fi
sudo mkdir -p /etc/docker
DAEMON_JSON=/etc/docker/daemon.json
if [[ -f "$DAEMON_JSON" ]]; then
  sudo python3 - <<PYEOF
import json
path = "$DAEMON_JSON"
try:
    cfg = json.load(open(path))
except Exception:
    cfg = {}
regs = cfg.get("insecure-registries", [])
if "$REGISTRY" not in regs:
    regs.append("$REGISTRY")
cfg["insecure-registries"] = regs
json.dump(cfg, open(path, "w"), indent=2)
print("Updated", path)
PYEOF
else
  sudo tee "$DAEMON_JSON" >/dev/null <<JSON
{
  "insecure-registries": ["${REGISTRY}"]
}
JSON
fi
sudo systemctl restart docker
success "Docker daemon configured."

# ── 4. Create hosts.toml on THIS node ─────────────────────────────────────────
# MicroK8s has its OWN containerd daemon — separate from Docker.
# Kubernetes uses this containerd (not Docker) to pull images into pods.
# Even on Node1, containerd contacts the registry over the network and
# expects TLS by default. hosts.toml tells it to use plain HTTP instead.
#
# Root cause of the error you saw:
#   "http: server gave HTTP response to HTTPS client"
# This happens on EVERY node (including Node1/jnode2) without this file.
create_hosts_toml_local() {
  local REG_IP="$1"
  local CERTS_DIR="/var/snap/microk8s/current/args/certs.d/${REG_IP}:32000"
  info "Writing hosts.toml for ${REG_IP}:32000 on this node ..."
  sudo mkdir -p "$CERTS_DIR"
  sudo tee "${CERTS_DIR}/hosts.toml" > /dev/null <<EOF
# Tells MicroK8s containerd to use plain HTTP for this registry.
# Required on EVERY cluster node — including the control-plane.
server = "http://${REG_IP}:32000"

[host."http://${REG_IP}:32000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
  success "hosts.toml written: ${CERTS_DIR}/hosts.toml"
}

create_hosts_toml_local "${NODE1_IP}"

info "Restarting MicroK8s containerd to apply hosts.toml ..."
sudo systemctl restart snap.microk8s.daemon-containerd
sleep 6
success "containerd restarted."

# ── 5. Configure hosts.toml on the worker node via SSH (if NODE2_IP is set) ───
# If the operator provided NODE2_IP, we SSH in and write the same hosts.toml
# there. This prevents ImagePullBackOff on pods scheduled to the worker.
if [[ -n "$NODE2_IP" ]]; then
  info "Configuring hosts.toml on worker node ${NODE2_IP} ..."
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "${NODE2_USER}@${NODE2_IP}" bash -s "${NODE1_IP}" <<'REMOTE'
set -euo pipefail
REG_IP="$1"
CERTS_DIR="/var/snap/microk8s/current/args/certs.d/${REG_IP}:32000"
sudo mkdir -p "$CERTS_DIR"
sudo tee "${CERTS_DIR}/hosts.toml" > /dev/null <<EOF
server = "http://${REG_IP}:32000"

[host."http://${REG_IP}:32000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
sudo systemctl restart snap.microk8s.daemon-containerd
sleep 4
echo "[worker] hosts.toml created and containerd restarted OK."
REMOTE
  success "Worker node ${NODE2_IP} configured."
else
  # Print manual instructions so the operator knows exactly what to do
  warn "NODE2_IP not set — worker node NOT auto-configured."
  echo ""
  echo -e "${YW}  ╔══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${YW}  ║  ACTION REQUIRED on your worker node before pods can pull images ║${NC}"
  echo -e "${YW}  ╠══════════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${YW}  ║  SSH into your worker node and run:                              ║${NC}"
  echo -e "${YW}  ║                                                                  ║${NC}"
  printf  "${YW}  ║  NODE1_IP=\"%-54s║${NC}\n" "${NODE1_IP}\""
  echo -e "${YW}  ║  CERTS_DIR=\"/var/snap/microk8s/current/args/certs.d/\${NODE1_IP}:32000\"  ║${NC}"
  echo -e "${YW}  ║  sudo mkdir -p \"\$CERTS_DIR\"                                     ║${NC}"
  echo -e "${YW}  ║  sudo tee \"\${CERTS_DIR}/hosts.toml\" > /dev/null <<EOF           ║${NC}"
  printf  "${YW}  ║  server = \"http://%s:32000\"%-29s║${NC}\n" "${NODE1_IP}" ""
  echo -e "${YW}  ║                                                                  ║${NC}"
  printf  "${YW}  ║  [host.\"http://%s:32000\"]%-29s║${NC}\n"   "${NODE1_IP}" ""
  echo -e "${YW}  ║    capabilities = [\"pull\", \"resolve\"]                           ║${NC}"
  echo -e "${YW}  ║    skip_verify = true                                            ║${NC}"
  echo -e "${YW}  ║  EOF                                                             ║${NC}"
  echo -e "${YW}  ║  sudo systemctl restart snap.microk8s.daemon-containerd          ║${NC}"
  echo -e "${YW}  ║                                                                  ║${NC}"
  echo -e "${YW}  ║  After that, run on Node1:                                       ║${NC}"
  echo -e "${YW}  ║    microk8s kubectl rollout restart deployment/webapp -n default  ║${NC}"
  echo -e "${YW}  ╚══════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
fi

# ── 6. Patch postgres manifest with the REAL hostname of this node ─────────────
# The nodeSelector value must exactly match `kubectl get nodes` output.
# We replace the placeholder string NODE1_HOSTNAME with the actual hostname
# reported by the OS — whatever that happens to be (jnode2, worker1, etc.)
MANIFEST_SRC="${REPO_ROOT}/manifests/postgres-lowram.yaml"
MANIFEST_TMP="/tmp/postgres-lowram-patched.yaml"
info "Patching Postgres nodeSelector: NODE1_HOSTNAME → ${NODE1_HOSTNAME}"
sed "s/NODE1_HOSTNAME/${NODE1_HOSTNAME}/g" "$MANIFEST_SRC" > "$MANIFEST_TMP"
grep "kubernetes.io/hostname" "$MANIFEST_TMP"
success "Postgres pinned to node: ${NODE1_HOSTNAME}"

# ── 7. Deploy PostgreSQL ──────────────────────────────────────────────────────
info "Applying PostgreSQL manifest ..."
microk8s kubectl apply -f "$MANIFEST_TMP"
info "Waiting up to 3 min for Postgres to be Available ..."
microk8s kubectl wait deployment/postgres \
  --for=condition=Available \
  --timeout=180s \
  --namespace=default
success "PostgreSQL is ready."

# ── 8. Build & push webapp Docker image ───────────────────────────────────────
info "Building Docker image: ${REGISTRY}/webapp:latest ..."
docker build -t "${REGISTRY}/webapp:latest" "${REPO_ROOT}/app"
info "Pushing to local registry ..."
docker push "${REGISTRY}/webapp:latest"

info "Verifying image in registry ..."
TAGS=$(curl -s "http://${REGISTRY}/v2/webapp/tags/list")
echo "  Registry response: ${TAGS}"
echo "$TAGS" | grep -q "latest" || die "Push failed — 'latest' not found. Check registry and Docker daemon config."
success "Image available at ${REGISTRY}/webapp:latest"

# ── 9. Helm install/upgrade webapp ────────────────────────────────────────────
info "Running helm upgrade --install (timeout 5m) ..."
microk8s helm3 upgrade --install webapp "${REPO_ROOT}/charts/webapp" \
  --set "image.repository=${REGISTRY}/webapp" \
  --set "image.tag=latest" \
  --set "postgres.host=postgres-service" \
  --wait \
  --timeout 5m \
  --namespace default
success "Helm release 'webapp' deployed."

# ── 10. Final status ──────────────────────────────────────────────────────────
echo ""
info "── Pods (NODE column shows real hostnames) ──"
microk8s kubectl get pods -o wide --namespace=default
echo ""
info "── Services ──"
microk8s kubectl get svc --namespace=default
echo ""
info "── Ingress ──"
microk8s kubectl get ingress --namespace=default
echo ""
info "── PVCs ──"
microk8s kubectl get pvc --namespace=default

echo ""
echo -e "${GR}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                   🚀 DEPLOYMENT COMPLETE                         ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
printf "║  App URL    :  http://%-43s║\n" "${NODE1_IP}/"
printf "║  Registry   :  http://%-43s║\n" "${REGISTRY}/v2/_catalog"
printf "║  This node  :  %-51s║\n" "${NODE1_HOSTNAME} (${NODE1_IP})"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  Useful commands:                                                ║"
echo "║    microk8s kubectl get pods -o wide                             ║"
echo "║    microk8s kubectl logs -l app=webapp -f                        ║"
echo "║    microk8s kubectl scale deploy/webapp --replicas=4             ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
