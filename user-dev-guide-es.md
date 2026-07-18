# Guía de Usuario y Desarrollador 🛠️

Bienvenido a la guía paso a paso sobre cómo poner en marcha el sistema MicroK8s DevOps y cómo desarrollar en él.

## 📌 Requisitos Previos
Antes de comenzar, asegúrate de tener:
* Una máquina (o dos) ejecutando un sistema operativo Linux (por ejemplo, Ubuntu).
* Al menos **2 núcleos de CPU** y **4 GB de RAM** por nodo.
* Una conexión de red local (LAN) entre los nodos si utilizas una configuración de múltiples nodos.

---

## 🚀 Paso 1: Instalación Inicial (Nodo de Control)
Toda la configuración inicial está completamente automatizada. Este script se encarga de instalar MicroK8s, configurar el registro local, desplegar la base de datos y arrancar la aplicación web.

1. Abre tu terminal en tu nodo principal (Nodo 1).
2. Otorga permisos de ejecución a los scripts:
   ```bash
   chmod +x scripts/*.sh
   ```
3. Ejecuta el script de instalación:
   ```bash
   ./scripts/install.sh
   ```

**¿Qué ocurre en segundo plano?**
* Se instala **MicroK8s** y se habilitan los complementos esenciales (dns, ingress, helm3, registry).
* Se configura un registro local de Docker en `localhost:32000`.
* Se despliega la base de datos PostgreSQL con límites de memoria ajustados.
* La aplicación web Flask en la carpeta `app/` se construye en una imagen Docker, se sube al registro y se despliega mediante Helm.

---

## 🔗 Paso 2: Añadir un Nodo Trabajador (Opcional)
Si tienes una segunda computadora para compartir la carga de trabajo, puedes configurarla fácilmente.

**Opción A: Configuración automática durante la instalación**
Si aún no has ejecutado `install.sh`, puedes hacerlo todo en un solo comando proporcionando la IP y el usuario de tu segundo nodo:
```bash
NODE2_IP=192.168.0.101 NODE2_USER=tuusuario ./scripts/install.sh
```

**Opción B: Configuración manual en el Nodo Trabajador**
Si el Nodo 1 ya está en funcionamiento, ve al Nodo 2 y ejecuta:
```bash
NODE1_IP=192.168.0.100 ./scripts/setup-worker-node.sh
```
*(Reemplaza `192.168.0.100` con la IP real del Nodo 1).*

---

## 💻 Paso 3: Flujo de Trabajo de Desarrollo
Cuando desees cambiar el código (como editar la aplicación Flask en la carpeta `app/`), no necesitas reinstalar todo.

1. Realiza los cambios de código en `app/main.py` o `app/templates/`.
2. Ejecuta el script de despliegue rápido:
   ```bash
   ./scripts/deploy-local.sh
   ```

**¿Qué ocurre?** El script reconstruye instantáneamente la imagen Docker, la sube a tu registro local y le ordena a Helm que actualice la aplicación sin tiempo de inactividad.

---

## 🤖 Paso 4: Habilitar GitOps (ArgoCD)
Para una experiencia similar a producción, puedes gestionar los despliegues automáticamente a través de ArgoCD.

1. Ejecuta el script de configuración de ArgoCD:
   ```bash
   ./scripts/setup-argocd.sh
   ```
2. ArgoCD ahora monitoreará el archivo `argocd/app.yaml` y se asegurará de que tu clúster siempre coincida con el modelo definido en Git. ¡Si eliminas manualmente un pod, ArgoCD lo recreará inmediatamente!

---

## 🔍 Paso 5: Comandos Útiles para Depuración
Aquí tienes los comandos más comunes que usarás para verificar el estado de tu sistema:

* **Listar todos los pods y ver en qué nodo se están ejecutando:**
  ```bash
  microk8s kubectl get pods -o wide --namespace=default
  ```
* **Ver los registros (logs) de la aplicación web en tiempo real:**
  ```bash
  microk8s kubectl logs -l app=webapp -f
  ```
* **Escalar la aplicación web a 4 instancias:**
  ```bash
  microk8s kubectl scale deploy/webapp --replicas=4
  ```
* **Desinstalar todo si algo se rompe:**
  ```bash
  ./scripts/uninstall.sh
  ```
