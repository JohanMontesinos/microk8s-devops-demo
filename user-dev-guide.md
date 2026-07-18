# User & Developer Guide 🛠️

Welcome to the step-by-step guide on how to get the MicroK8s DevOps system up and running, and how to develop against it.

## 📌 Prerequisites
Before you start, ensure you have:
* A machine (or two) running a Linux OS (e.g., Ubuntu).
* At least **2 CPU Cores** and **4 GB of RAM** per node.
* A local network connection (LAN) between nodes if using a multi-node setup.

---

## 🚀 Step 1: Initial Installation (Control Plane Node)
The entire initial setup is completely automated. This script handles installing MicroK8s, configuring the local registry, deploying the database, and starting the web application.

1. Open your terminal on your main node (Node 1).
2. Give execution permissions to the scripts:
   ```bash
   chmod +x scripts/*.sh
   ```
3. Run the installation script:
   ```bash
   ./scripts/install.sh
   ```

**What happens in the background?**
* **MicroK8s** is installed and essential add-ons (dns, ingress, helm3, registry) are enabled.
* A local Docker registry is configured at `localhost:32000`.
* The PostgreSQL database is deployed with aggressive memory limits.
* The Flask web application in `app/` is built into a Docker image, pushed to the registry, and deployed via Helm.

---

## 🔗 Step 2: Adding a Worker Node (Optional)
If you have a second computer to share the workload, you can configure it easily.

**Option A: Auto-setup during installation**
If you haven't run `install.sh` yet, you can do it all in one command by providing the IP and user of your second node:
```bash
NODE2_IP=192.168.0.101 NODE2_USER=yourusername ./scripts/install.sh
```

**Option B: Manual setup on the Worker Node**
If Node 1 is already running, go to Node 2 and run:
```bash
NODE1_IP=192.168.0.100 ./scripts/setup-worker-node.sh
```
*(Replace `192.168.0.100` with the actual IP of Node 1).*

---

## 💻 Step 3: The Development Workflow
When you want to change the code (like editing the Flask app in the `app/` folder), you don't need to reinstall everything. 

1. Make your code changes in `app/main.py` or `app/templates/`.
2. Run the fast deployment script:
   ```bash
   ./scripts/deploy-local.sh
   ```

**What happens?** The script instantly rebuilds the Docker image, pushes it to your local registry, and commands Helm to upgrade the application without downtime.

---

## 🤖 Step 4: Enabling GitOps (ArgoCD)
For a production-like experience, you can manage deployments automatically via ArgoCD.

1. Run the ArgoCD setup script:
   ```bash
   ./scripts/setup-argocd.sh
   ```
2. ArgoCD will now monitor the `argocd/app.yaml` file and ensure your cluster always matches the blueprint defined in Git. If you manually delete a pod, ArgoCD will immediately recreate it!

---

## 🔍 Step 5: Useful Commands for Debugging
Here are the most common commands you will use to check the health of your system:

* **List all pods and see which node they are running on:**
  ```bash
  microk8s kubectl get pods -o wide --namespace=default
  ```
* **View the logs of the web application live:**
  ```bash
  microk8s kubectl logs -l app=webapp -f
  ```
* **Scale the web application to 4 instances:**
  ```bash
  microk8s kubectl scale deploy/webapp --replicas=4
  ```
* **Uninstall everything if things break:**
  ```bash
  ./scripts/uninstall.sh
  ```
