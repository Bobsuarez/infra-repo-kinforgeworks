#!/usr/bin/env bash
# Instala k3s de forma idempotente y deja un kubeconfig usable en $HOME/.kube/config.
set -euo pipefail

if command -v k3s >/dev/null 2>&1 && systemctl is-active --quiet k3s; then
  echo "==> k3s ya está instalado y activo, se omite la instalación."
else
  echo "==> Instalando k3s..."
  curl -sfL https://get.k3s.io | sh -
fi

echo "==> Esperando a que el nodo quede Ready..."
for i in $(seq 1 30); do
  if sudo k3s kubectl get nodes 2>/dev/null | awk 'NR>1 {print $2}' | grep -q '^Ready$'; then
    break
  fi
  sleep 5
done
sudo k3s kubectl get nodes

mkdir -p "$HOME/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

echo "==> k3s listo. kubeconfig en $HOME/.kube/config"
