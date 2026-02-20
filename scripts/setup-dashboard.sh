#!/usr/bin/env bash
# Enable the MicroK8s Kubernetes dashboard and print a login token.
set -euo pipefail

echo "[dashboard] Enabling dashboard addon ..."
microk8s enable dashboard

echo "[dashboard] Waiting for dashboard deployment ..."
microk8s kubectl wait deployment/kubernetes-dashboard \
  --for=condition=Available \
  --timeout=120s \
  --namespace=kube-system

# Retrieve a token for the default service account.
# On newer Kubernetes, secrets are no longer auto-created; use 'create token' instead.
TOKEN=$(microk8s kubectl -n kube-system create token default 2>/dev/null || \
  microk8s kubectl -n kube-system get secret \
    "$(microk8s kubectl -n kube-system get sa/default -o jsonpath='{.secrets[0].name}')" \
    -o jsonpath="{.data.token}" | base64 -d)

NODE1_IP="${NODE1_IP:-$(hostname -I | awk '{print $1}')}"

echo ""
echo "════════════════════════════════════════════════"
echo "  Dashboard — access options:"
echo ""
echo "  Option 1: kubectl proxy (local only)"
echo "    microk8s kubectl proxy &"
echo "    Open: http://localhost:8001/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/"
echo ""
echo "  Option 2: NodePort (LAN access)"
echo "    microk8s kubectl -n kube-system patch svc kubernetes-dashboard \\"
echo "      -p '{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":443,\"nodePort\":31000,\"targetPort\":8443}]}}'"
echo "    Open: https://${NODE1_IP}:31000"
echo ""
echo "  Login Token:"
echo "  ${TOKEN}"
echo "════════════════════════════════════════════════"
