#!/usr/bin/env bash
# Install lightweight observability for 4 GB RAM nodes.
# Default: metrics-server only (safe).
# Optional: kube-prometheus-stack (uses 500-700 MB — read warning below).
set -euo pipefail

MODE="${1:-metrics}"    # Pass "prometheus" as $1 to install kube-prom-stack

if [[ "$MODE" == "prometheus" ]]; then
  echo ""
  echo "╔═══════════════════════════════════════════════════════════════╗"
  echo "║  WARNING: kube-prometheus-stack                               ║"
  echo "║  Prometheus + Grafana + AlertManager use 500-700 MB RAM.     ║"
  echo "║  On 4 GB nodes this leaves < 500 MB headroom for OS + DNS.  ║"
  echo "║  OOMKill risk is HIGH. Recommended only for demo purposes.   ║"
  echo "╚═══════════════════════════════════════════════════════════════╝"
  echo ""
  read -r -p "Continue anyway? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || exit 0

  microk8s helm3 repo add prometheus-community \
    https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  microk8s helm3 repo update

  # Minimal install: disable Alertmanager, reduce retention, limit resources
  microk8s helm3 upgrade --install kube-prom prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace \
    --set alertmanager.enabled=false \
    --set prometheus.prometheusSpec.retention=2h \
    --set prometheus.prometheusSpec.resources.requests.memory=256Mi \
    --set prometheus.prometheusSpec.resources.limits.memory=512Mi \
    --set grafana.resources.requests.memory=128Mi \
    --set grafana.resources.limits.memory=256Mi \
    --wait --timeout 10m

  echo "[observability] kube-prometheus-stack installed in namespace 'monitoring'."
  echo "  Access Grafana: microk8s kubectl -n monitoring port-forward svc/kube-prom-grafana 3000:80"
  echo "  Default credentials: admin / prom-operator"

else
  echo "[observability] Enabling metrics-server (lightweight, ~30 MB) ..."
  microk8s enable metrics-server
  echo "[observability] Done."
  echo "  Try: microk8s kubectl top nodes"
  echo "  Try: microk8s kubectl top pods"
fi
