#!/usr/bin/env bash
# Install the Kubernetes Dashboard using kubectl apply (direct manifest).
#
# WHY NOT `microk8s enable dashboard`:
#   MicroK8s 1.28's dashboard addon internally runs `helm install` against
#   https://kubernetes.github.io/dashboard/ — a URL that now returns 404
#   because the Kubernetes Dashboard project restructured its Helm repository.
#   Bypassing the addon and applying the official manifest directly is more
#   reliable and does not depend on any Helm repository being reachable.
#
# WHAT THIS INSTALLS:
#   Kubernetes Dashboard v2.7.0 — the last stable v2 release.
#   v3 requires a completely different architecture (auth-proxy, kong gateway)
#   that is too heavy for 4 GB RAM nodes. v2.7.0 is stable and LTS-supported.
#
# ACCESS:
#   NodePort 31000 on Node1 — https://NODE1_IP:31000
#   Login with the token printed at the end of this script.
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
CY='\033[0;36m'; GR='\033[0;32m'; YW='\033[0;33m'; NC='\033[0m'
info()    { echo -e "${CY}[INFO]${NC}  $*"; }
success() { echo -e "${GR}[OK]${NC}    $*"; }
warn()    { echo -e "${YW}[WARN]${NC}  $*"; }

NODE1_IP="${NODE1_IP:-$(hostname -I | awk '{print $1}')}"

# Pin to v2.7.0 — a known-good version that works with MicroK8s 1.28.
# This URL is a stable raw GitHub link that does not change.
DASHBOARD_VERSION="v2.7.0"
DASHBOARD_MANIFEST="https://raw.githubusercontent.com/kubernetes/dashboard/${DASHBOARD_VERSION}/aio/deploy/recommended.yaml"

# ── 1. Apply the dashboard manifest ───────────────────────────────────────────
# `recommended.yaml` creates its own namespace (kubernetes-dashboard),
# the dashboard Deployment, Service, RBAC roles, and ServiceAccount in one shot.
# No Helm, no repo, no internet dependency beyond raw.githubusercontent.com.
info "Applying Kubernetes Dashboard ${DASHBOARD_VERSION} manifest ..."
microk8s kubectl apply -f "$DASHBOARD_MANIFEST"
success "Manifest applied."

# ── 2. Wait for the dashboard pod to be ready ─────────────────────────────────
info "Waiting for dashboard deployment to be Available (up to 3 min) ..."
microk8s kubectl wait deployment/kubernetes-dashboard \
  --for=condition=Available \
  --timeout=180s \
  --namespace=kubernetes-dashboard
success "Dashboard is running."

# ── 3. Create an admin ServiceAccount for login ───────────────────────────────
# The dashboard's built-in ServiceAccount has minimal RBAC permissions.
# We create a dedicated admin account so you can see all namespaces and
# resources during the demo without hitting "forbidden" errors.
info "Creating admin-user ServiceAccount ..."
microk8s kubectl apply -f - <<EOF
---
# ServiceAccount that the dashboard token will be issued for
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard

---
# Bind the built-in cluster-admin ClusterRole to our admin-user.
# cluster-admin has full read/write access to every resource — appropriate
# for a local demo cluster, but do NOT use this in production.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: admin-user
    namespace: kubernetes-dashboard
EOF
success "admin-user ServiceAccount created."

# ── 4. Expose the dashboard via NodePort ──────────────────────────────────────
# The default Service type is ClusterIP (only reachable inside the cluster).
# Patching it to NodePort 31000 makes it reachable from your LAN and MacBook.
info "Exposing dashboard on NodePort 31000 ..."
microk8s kubectl -n kubernetes-dashboard patch svc kubernetes-dashboard \
  -p '{"spec":{"type":"NodePort","ports":[{"port":443,"targetPort":8443,"nodePort":31000}]}}'
success "NodePort 31000 configured."

# ── 5. Generate a login token ─────────────────────────────────────────────────
# `kubectl create token` issues a short-lived token (default: 1 hour).
# This is the recommended approach in Kubernetes 1.24+ where Secret-based
# tokens are no longer auto-created for ServiceAccounts.
info "Generating login token for admin-user ..."
TOKEN=$(microk8s kubectl -n kubernetes-dashboard create token admin-user --duration=24h)
success "Token generated (valid 24 hours)."

# ── 6. Print access instructions ──────────────────────────────────────────────
echo ""
echo -e "${GR}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║             Kubernetes Dashboard Ready                           ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
printf "║  URL:  https://%-51s║\n" "${NODE1_IP}:31000"
echo "║                                                                  ║"
echo "║  Select: Token                                                   ║"
echo "║  Paste the token printed below                                   ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  From your MacBook — copy kubeconfig and use kubectl:            ║"
printf "║    scp USER@%s:~/microk8s-kubeconfig.yaml ~/.kube/  ║\n" "${NODE1_IP}"
echo "║    export KUBECONFIG=~/.kube/microk8s-kubeconfig.yaml           ║"
printf "║    kubectl top nodes   # requires metrics-server                ║"
echo "  ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  To regenerate a fresh token any time:                           ║"
echo "║    microk8s kubectl -n kubernetes-dashboard \\                   ║"
echo "║      create token admin-user --duration=24h                      ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo "── LOGIN TOKEN (copy everything between the lines) ──────────────────"
echo ""
echo "$TOKEN"
echo ""
echo "─────────────────────────────────────────────────────────────────────"
echo ""
warn "The browser will warn about an untrusted certificate (self-signed)."
warn "Click 'Advanced' → 'Proceed anyway' to continue."
