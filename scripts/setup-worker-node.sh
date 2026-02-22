#!/usr/bin/env bash
# Run this script ON THE WORKER NODE (e.g. jnode1) after joining the cluster.
# It configures hosts.toml so containerd can pull images from Node1's HTTP registry.
#
# Usage (run on the worker node):
#   NODE1_IP=192.168.0.102 ./setup-worker-node.sh
#
# Or pipe directly from Node1 over SSH:
#   NODE1_IP=192.168.0.102
#   ssh johan@WORKER_IP "NODE1_IP=${NODE1_IP} bash -s" < scripts/setup-worker-node.sh
set -euo pipefail

CY='\033[0;36m'; GR='\033[0;32m'; RD='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${CY}[INFO]${NC}  $*"; }
success() { echo -e "${GR}[OK]${NC}    $*"; }
die()     { echo -e "${RD}[ERROR]${NC} $*" >&2; exit 1; }

[[ -z "${NODE1_IP:-}" ]] && die "Set NODE1_IP before running: NODE1_IP=192.168.x.x ./setup-worker-node.sh"

CERTS_DIR="/var/snap/microk8s/current/args/certs.d/${NODE1_IP}:32000"

info "Worker node hostname: $(hostname)"
info "Creating hosts.toml for registry at ${NODE1_IP}:32000 ..."

sudo mkdir -p "$CERTS_DIR"
sudo tee "${CERTS_DIR}/hosts.toml" > /dev/null <<EOF
# Tells MicroK8s containerd to use plain HTTP for the Node1 registry.
# Without this file, pulls fail with:
#   "http: server gave HTTP response to HTTPS client"
server = "http://${NODE1_IP}:32000"

[host."http://${NODE1_IP}:32000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF

success "hosts.toml written to ${CERTS_DIR}/hosts.toml"
info "Restarting MicroK8s containerd ..."
sudo systemctl restart snap.microk8s.daemon-containerd
sleep 5

info "Verifying registry connectivity ..."
curl -sf "http://${NODE1_IP}:32000/v2/_catalog" && echo "" || {
  echo "Warning: cannot reach registry yet — check firewall on Node1:"
  echo "  sudo ufw allow 32000/tcp && sudo ufw reload"
}

success "Worker node $(hostname) configured. Images from ${NODE1_IP}:32000 can now be pulled."
