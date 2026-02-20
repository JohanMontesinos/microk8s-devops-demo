# Interview Demo Script (5–8 minutes)

> Tip: open two terminal panes side by side — one for `watch` commands,
> one for interactive commands. This makes the live demo more compelling.

---

## Section 1 — Introduction (0:00–0:40)

**Say:** "This project demonstrates a production-style Kubernetes workflow on
constrained hardware — two nodes, 4 GB RAM each, no cloud services, no internet
dependency at runtime. I'll walk through multi-node scheduling, soft pod spreading,
GitOps with ArgoCD, and PostgreSQL running inside the cluster."

```bash
# Show the architecture diagram
cat docs/architecture.md | head -50
```

**Point out:** the Mermaid diagram shows traffic flowing Browser → Ingress →
Service → two webapp pods on different nodes, and both pods connecting to a
single PostgreSQL instance on Node1.

---

## Section 2 — Node Inspection (0:40–1:30)

```bash
# Confirm both nodes are Ready and show their LAN IPs
microk8s kubectl get nodes -o wide

# Check which addons are enabled
microk8s status

# Show how resources are allocated across the cluster
microk8s kubectl describe nodes | grep -A8 "Allocatable:"

# Show current resource usage (requires metrics-server)
microk8s kubectl top nodes
```

**Point out:** two nodes, both `Ready`, ingress and registry addons enabled.
Node2 shows no control-plane components — it's a pure worker.

---

## Section 3 — Registry Inspection (1:30–2:15)

```bash
NODE1_IP=$(hostname -I | awk '{print $1}')

# List all images stored in the local registry
curl -s http://${NODE1_IP}:32000/v2/_catalog
# Expected: {"repositories":["webapp"]}

# Show available tags for the webapp image
curl -s http://${NODE1_IP}:32000/v2/webapp/tags/list
# Expected: {"name":"webapp","tags":["latest"]}

# Show the hosts.toml fix on Node2 (SSH in or show the file if running on Node2)
# This is what allows Node2 to pull images from Node1's HTTP registry
cat /var/snap/microk8s/current/args/certs.d/${NODE1_IP}:32000/hosts.toml
```

**Explain:** without `hosts.toml`, containerd on Node2 tries TLS against an HTTP
registry and fails. The file tells containerd to use plain HTTP and skip cert
verification for this specific registry endpoint.

---

## Section 4 — Deployment Walkthrough (2:15–3:30)

```bash
# Show the postgres manifest — highlight RAM tuning args
cat manifests/postgres-lowram.yaml

# Show values.yaml — highlight replicaCount and spreading config
cat charts/webapp/values.yaml

# Show the deployment template — highlight topologySpreadConstraints
grep -A12 "topologySpreadConstraints" charts/webapp/templates/deployment.yaml

# Show the anti-affinity config
grep -A10 "podAntiAffinity" charts/webapp/templates/deployment.yaml

# Confirm the Helm release is installed
microk8s helm3 list --namespace default
```

**Explain key decisions:**
- `shared_buffers=32MB` — PostgreSQL normally defaults to 128 MB; we cut it to
  stay within the 256 MB memory limit
- `max_connections=20` — each idle connection uses ~5 MB; 20 caps overhead at 100 MB
- `whenUnsatisfiable: ScheduleAnyway` — this is the critical flag that ensures
  pods NEVER go Pending even if only one node is available
- `preferredDuringScheduling...` — soft anti-affinity; the scheduler tries to
  spread but won't block if it can't

---

## Section 5 — Live Spreading Demo (3:30–4:30)

```bash
# In pane 1: start a live watch
watch -n1 "microk8s kubectl get pods -o wide --namespace=default"

# In pane 2: scale up
microk8s kubectl scale deployment/webapp --replicas=4

# Observe pods distributing across node1 and node2 (2 on each)
# The NODE column in the output shows which physical node each pod runs on

# Scale back to default
microk8s kubectl scale deployment/webapp --replicas=2

# Confirm final state
microk8s kubectl get pods -o wide --namespace=default
```

**What to show:** with 2 nodes, 4 replicas distribute 2+2. With only 1 node
available, all 4 still schedule — no Pending state — because `ScheduleAnyway`
allows the constraint to be violated.

---

## Section 6 — App Demo (4:30–5:15)

```bash
NODE1_IP=$(hostname -I | awk '{print $1}')

# Test the app from the command line
curl -s http://${NODE1_IP}/ | grep -E "pod_name|node_name|db_status"

# Run it multiple times to see different pods responding
for i in {1..6}; do
  curl -s http://${NODE1_IP}/ | grep -E "Pod Name|Node Name" | head -2
  echo "---"
  sleep 0.5
done

# Check the health probe endpoint (used by Kubernetes liveness checks)
curl -v http://${NODE1_IP}/healthz
```

**Open in browser:** navigate to `http://NODE1_IP/` and refresh several times.
Point out the `Pod Name` and `Node Name` fields changing — this proves the nginx
ingress is load-balancing across pods on different nodes.

---

## Section 7 — PostgreSQL Connectivity Test (5:15–5:45)

```bash
# Option A: exec into the postgres pod directly
PG_POD=$(microk8s kubectl get pod -l app=postgres \
  -o jsonpath='{.items[0].metadata.name}')

microk8s kubectl exec -it "$PG_POD" -- \
  psql -U appuser -d appdb -c "SELECT version();"

# Option B: test from inside a webapp pod (proves in-cluster DNS resolution works)
WEBAPP_POD=$(microk8s kubectl get pod -l app=webapp \
  -o jsonpath='{.items[0].metadata.name}')

microk8s kubectl exec -it "$WEBAPP_POD" -- \
  python3 -c "
import psycopg2
conn = psycopg2.connect(
    host='postgres-service',
    dbname='appdb',
    user='appuser',
    password='apppassword',
    connect_timeout=5
)
cur = conn.cursor()
cur.execute('SELECT version();')
print('DB connected OK:', cur.fetchone()[0])
conn.close()
"
```

**Explain:** Option B is the more realistic test — it shows that CoreDNS resolves
`postgres-service` to the ClusterIP, and the webapp container can reach Postgres
across the cluster network even though it may be running on Node2.

---

## Section 8 — Wrap-Up (5:45–7:30)

**Say:** "To summarise what we've built and demonstrated:"

```bash
# Final state overview
microk8s kubectl get all --namespace=default
microk8s kubectl get pvc --namespace=default
microk8s helm3 list --namespace=default
```

**Key concepts demonstrated:**

- **2-node MicroK8s cluster** on 4 GB RAM hardware using only open-source tooling
- **Soft pod spreading** — `ScheduleAnyway` + `preferredDuringScheduling` ensures
  pods distribute across nodes when possible but never get stuck Pending
- **Local container registry** — zero external dependency after initial setup;
  Node2 pulls images via `hosts.toml` HTTP override
- **PostgreSQL tuned for 256 MB RAM** — explicit server flags override defaults
  designed for servers with gigabytes of memory
- **Helm chart** — fully parameterised, values-driven, GitOps-ready
- **ArgoCD** — pulls from local Gitea, self-heals if someone manually edits the cluster
- **GitHub Actions CI** — SSH-based deploy pipeline; no persistent runner agent
  on Node1

**Close with:** "All patterns shown here — topology spreading, Downward API,
resource limits, Helm values overrides, GitOps sync — transfer directly to
production EKS, GKE, or AKS clusters. The only thing that changes is the
infrastructure underneath."
