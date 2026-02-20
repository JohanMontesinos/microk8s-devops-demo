#!/usr/bin/env bash
# Install ArgoCD and expose via NodePort 30080 (HTTP) and 30443 (HTTPS).
set -euo pipefail

NODE1_IP="${NODE1_IP:-$(hostname -I | awk '{print $1}')}"
ARGOCD_NS="argocd"

echo "[argocd] Creating namespace ..."
microk8s kubectl create namespace "$ARGOCD_NS" --dry-run=client -o yaml | \
  microk8s kubectl apply -f -

echo "[argocd] Installing ArgoCD (stable) ..."
# WHY --server-side:
#   The default `kubectl apply` (client-side) stores the full manifest in a
#   "last-applied-configuration" annotation on each resource so it can compute
#   diffs on the next apply. ArgoCD's CRDs (e.g. applicationsets.argoproj.io)
#   are so large that this annotation exceeds Kubernetes' 262144-byte limit,
#   causing the error:
#     "The CustomResourceDefinition is invalid:
#      metadata.annotations: Too long: may not be more than 262144 bytes"
#
#   --server-side moves the apply logic to the API server, which uses a leaner
#   "managed fields" mechanism instead of that annotation — no size limit hit.
#
# WHY --force-conflicts:
#   On a first install there are no conflicts, but if you re-run after a partial
#   install, the API server may see field ownership conflicts between the old
#   client-side apply and the new server-side apply. --force-conflicts lets the
#   server-side apply take ownership without erroring out.
microk8s kubectl apply \
  --server-side \
  --force-conflicts \
  -n "$ARGOCD_NS" \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "[argocd] Waiting for server deployment (up to 3 min) ..."
microk8s kubectl wait deployment/argocd-server \
  --for=condition=Available \
  --timeout=180s \
  --namespace="$ARGOCD_NS"

echo "[argocd] Patching argocd-server service to NodePort ..."
microk8s kubectl -n "$ARGOCD_NS" patch svc argocd-server \
  -p '{"spec":{"type":"NodePort","ports":[{"name":"http","port":80,"nodePort":30080,"targetPort":8080},{"name":"https","port":443,"nodePort":30443,"targetPort":8080}]}}'

# The initial admin password is stored in a secret created by ArgoCD at install time.
ARGOCD_PASS=$(microk8s kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                  ArgoCD Ready                                ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  URL:      https://%-41s║\n" "${NODE1_IP}:30443"
echo "║  Username: admin                                             ║"
printf "║  Password: %-49s║\n" "${ARGOCD_PASS}"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Next step — apply the ArgoCD Application:                   ║"
echo "║    Edit argocd/app.yaml and replace NODE1_IP, then:          ║"
echo "║    microk8s kubectl apply -f argocd/app.yaml                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
