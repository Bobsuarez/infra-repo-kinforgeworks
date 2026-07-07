#!/usr/bin/env bash
# Instala ArgoCD (incluye ApplicationSet controller) de forma idempotente.
set -euo pipefail
export KUBECONFIG="$HOME/.kube/config"

kubectl get namespace argocd >/dev/null 2>&1 || kubectl create namespace argocd

echo "==> Aplicando manifests de ArgoCD (stable)..."
# --server-side: el CRD applicationsets.argoproj.io supera el límite de 262144
# bytes para la anotación kubectl.kubernetes.io/last-applied-configuration que
# usa el apply "client-side" normal. Server-side apply no depende de esa
# anotación. --force-conflicts para que sea idempotente entre corridas.
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "==> Esperando a que los deployments de argocd estén disponibles..."
kubectl -n argocd wait --for=condition=Available deployment --all --timeout=300s

echo "==> Contraseña inicial de admin (rótala después del primer login):"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
echo
