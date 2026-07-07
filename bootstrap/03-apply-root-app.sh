#!/usr/bin/env bash
# Registra el repo en ArgoCD (si es privado) y aplica el root-app (ApplicationSet
# "app of apps"): a partir de ahí, agregar un proyecto nuevo es solo agregar una
# carpeta en apps/ y hacer push - ArgoCD la detecta y crea su Application sola.
set -euo pipefail
export KUBECONFIG="$HOME/.kube/config"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://github.com/Bobsuarez/infra-repo-kinforgeworks.git"

if [ -n "${ARGOCD_REPO_TOKEN:-}" ]; then
  echo "==> Registrando credenciales del repo en ArgoCD (repo privado)..."
  kubectl apply -n argocd -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: infra-repo-kinforgeworks
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${REPO_URL}
  username: git
  password: ${ARGOCD_REPO_TOKEN}
EOF
else
  echo "==> ARGOCD_REPO_TOKEN no definido: se asume repo público o ya registrado a mano en ArgoCD."
fi

echo "==> Aplicando sealed-secrets (controller de plataforma)..."
kubectl apply -f "${SCRIPT_DIR}/../clusters/contabo-vps/sealed-secrets-app.yaml"

echo "==> Aplicando root-app..."
kubectl apply -f "${SCRIPT_DIR}/../clusters/contabo-vps/root-app.yaml"

echo "==> Aplicaciones detectadas por ArgoCD:"
kubectl -n argocd get applications.argoproj.io 2>/dev/null || echo "(todavía no sincroniza, correr de nuevo en un minuto)"
