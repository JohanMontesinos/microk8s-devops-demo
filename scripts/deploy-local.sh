#!/usr/bin/env bash
# Quick rebuild: Docker build -> push -> helm upgrade only.
# Use this after editing app/ source code. Does not reinstall MicroK8s.
#
# Optional env vars:
#   NODE1_IP   — override auto-detected LAN IP
#   NODE2_IP   — if set, also restarts containerd on the worker after push
#   NODE2_USER — SSH user for worker (default: $USER)
set -euo pipefail

NODE1_IP="${NODE1_IP:-$(hostname -I | awk '{print $1}')}"
NODE2_IP="${NODE2_IP:-}"
NODE2_USER="${NODE2_USER:-$USER}"
REGISTRY="${NODE1_IP}:32000"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "[deploy] Building ${REGISTRY}/webapp:latest ..."
docker build -t "${REGISTRY}/webapp:latest" "${REPO_ROOT}/app"

echo "[deploy] Pushing to local registry ..."
docker push "${REGISTRY}/webapp:latest"

echo "[deploy] Helm upgrade ..."
microk8s helm3 upgrade webapp "${REPO_ROOT}/charts/webapp" \
  --set "image.repository=${REGISTRY}/webapp" \
  --set "image.tag=latest" \
  --reuse-values \
  --wait \
  --timeout 5m \
  --namespace default

echo "[deploy] Done. Current pods:"
microk8s kubectl get pods -o wide --namespace=default
