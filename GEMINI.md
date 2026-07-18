# Gemini AI Context (GEMINI.md)

Hello! If you are an AI assistant (like Gemini) reading this file, you are assisting with the `microk8s-devops-demo` repository. Please use this document to understand the context, constraints, and guidelines for this project.

## 📌 Project Context
This is a production-style, bare-metal Kubernetes DevOps project using **MicroK8s**. 
The most critical aspect of this project is that it is designed to run on **highly constrained hardware**.

**Hardware Limitations per Node:**
* **CPU:** 2 Cores
* **RAM:** 4 GB
* **Network:** LAN-only, no cloud services (no AWS, GCP, Azure).

## 🛠️ Tech Stack
* **Orchestrator:** MicroK8s (Canonical)
* **Application:** Python 3, Flask, Docker (multi-stage builds)
* **Database:** PostgreSQL (aggressively tuned for low RAM)
* **Deployment:** Helm, raw Kubernetes Manifests
* **GitOps:** ArgoCD
* **Automation:** Bash scripts
* **CI/CD:** GitHub Actions (SSH-based to local network)

## ⚖️ Rules & Guidelines for AI Output
When generating code, manifests, or scripts for this project, you **MUST** adhere to the following rules:

1. **Resource Efficiency is King:** Always set CPU and Memory requests/limits for Kubernetes pods. Keep them as low as functionally possible. Avoid suggesting memory-hungry tools like Elasticsearch, massive Prometheus stacks (unless heavily tuned), or heavy storage drivers like Longhorn.
2. **Offline / Local First:** Do not assume cloud resources (like Cloud LoadBalancers, cloud-based dynamic provisioning). Use NodePorts, hostPath PVCs, MetalLB, and the built-in MicroK8s registry (`localhost:32001`).
3. **Keep it Simple:** Prefer simple bash scripts for automation over complex configuration management tools if the task is relatively small. 
4. **Security Basics:** Applications should run as non-root users.
5. **No Cloud Magic:** If networking is required, assume standard MetalLB or NodePort on a local `192.168.X.X` network.

## 👤 User Context
The user's name is **Johan**. Johan likes Coding, AI, Building Things, Walking, Running, and helping other people learn the things he knows. 
*Keep your explanations helpful, educational, and structured so Johan can use them to teach others!*
