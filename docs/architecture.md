# Architecture

## System Diagram

```mermaid
graph TB
    subgraph CI["CI/CD (GitHub Actions)"]
        GHA[GitHub Actions Runner\nubuntu-latest hosted]
    end

    subgraph GitOps["GitOps Layer"]
        GITEA[Gitea\nhttp://Node1:3000]
        ARGOWATCH[ArgoCD watches\npoll interval 3 min]
    end

    subgraph Node1["Node1 — Control Plane + Worker  (4 GB RAM)"]
        INGRESS[Nginx Ingress Controller\nNodePort :80]
        SVC[webapp ClusterIP Service\nport 80 -> 5000]
        POD1[webapp Pod 1\nFlask + Gunicorn\n2 workers]
        PG[PostgreSQL Pod\npostgres:15-alpine\nlow-RAM tuned]
        PVC[(PVC 2Gi\nmicrok8s-hostpath)]
        REG[Container Registry\n:32000 HTTP]
        ARGOCD[ArgoCD Server\nNodePort :30443]
    end

    subgraph Node2["Node2 — Worker  (4 GB RAM)"]
        POD2[webapp Pod 2\nFlask + Gunicorn\n2 workers]
    end

    BROWSER([Browser]) -->|HTTP :80| INGRESS
    INGRESS --> SVC
    SVC -->|round-robin| POD1
    SVC -->|round-robin| POD2

    POD1 -->|psycopg2 :5432| PG
    POD2 -->|psycopg2 :5432| PG
    PG --- PVC

    REG -.->|image pull| POD1
    REG -.->|"image pull\nNODE1_IP:32000"| POD2

    GHA -->|"rsync + SSH\n(no runner on Node1)"| Node1
    GHA -->|docker push| REG

    GITEA --> ARGOWATCH
    ARGOWATCH --> ARGOCD
    ARGOCD -->|"helm sync\n(self-healing)"| SVC

    POD2 -. "soft spread\nScheduleAnyway" .-> POD1
```

---

## RAM Budget

Estimated resident memory per component. "Typical RSS" is observed at idle;
"Limit" is the Kubernetes hard limit configured in the manifests.

| Component | Node1 (MB) | Node2 (MB) | Typical RSS | Limit |
|---|---|---|---|---|
| Ubuntu OS + kernel | 400 | 400 | — | — |
| MicroK8s API server + etcd | 250 | 50 | varies | — |
| CoreDNS (2 replicas) | 40 | — | 20 MB each | 170 Mi |
| Nginx Ingress Controller | 80 | — | ~60 MB | 512 Mi |
| Container Registry | 50 | — | ~40 MB | — |
| PostgreSQL (limit 256 Mi) | 180 | — | ~150 MB | 256 Mi |
| webapp Pod x1 (limit 256 Mi) | 150 | 150 | ~100 MB | 256 Mi |
| metrics-server | 30 | — | ~25 MB | 100 Mi |
| ArgoCD (optional) | 300 | — | ~250 MB | — |
| **Total (without ArgoCD)** | **~1,180** | **~600** | | |
| **Free headroom** | **~2,820** | **~3,400** | | |
| **Total (with ArgoCD)** | **~1,480** | **~600** | | |
| **Free headroom (ArgoCD)** | **~2,520** | **~3,400** | | |

> **Safe threshold:** keep total reserved memory below 3,072 MB (3 GB) per node
> to maintain OS stability under burst conditions.
>
> **Do NOT install kube-prometheus-stack** on these nodes — it adds 500–700 MB
> and will cause OOMKill events. Use `metrics-server` instead.
